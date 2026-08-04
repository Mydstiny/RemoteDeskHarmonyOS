use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::{Dimensions, Scroll};
use alacritty_terminal::term::cell::{Cell as AlacrittyCell, Flags};
use alacritty_terminal::term::{Config as AlacrittyConfig, Term, TermDamage, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb};

use super::cell::{xterm_256_color, CellAttrs, DEFAULT_BG, DEFAULT_FG};
use super::snapshot::{SnapshotCell, TerminalSnapshot};

const DEFAULT_SCROLLBACK: usize = 3000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AlacrittyTerminalConfig {
    pub default_foreground: u32,
    pub default_background: u32,
    pub scrollback_lines: usize,
}

impl Default for AlacrittyTerminalConfig {
    fn default() -> Self {
        Self {
            default_foreground: DEFAULT_FG,
            default_background: DEFAULT_BG,
            scrollback_lines: DEFAULT_SCROLLBACK,
        }
    }
}

#[derive(Clone, Copy)]
struct TerminalSize {
    cols: usize,
    rows: usize,
}

impl Dimensions for TerminalSize {
    fn total_lines(&self) -> usize {
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

pub struct AlacrittyTerminal {
    term: Term<VoidListener>,
    parser: Processor,
    config: AlacrittyTerminalConfig,
    appearance_dirty: bool,
}

impl AlacrittyTerminal {
    pub fn new(cols: usize, rows: usize, config: AlacrittyTerminalConfig) -> Self {
        let size = TerminalSize {
            cols: cols.max(1),
            rows: rows.max(1),
        };
        let term_config = AlacrittyConfig {
            scrolling_history: config.scrollback_lines,
            ..AlacrittyConfig::default()
        };
        Self {
            term: Term::new(term_config, &size, VoidListener),
            parser: Processor::new(),
            config,
            appearance_dirty: true,
        }
    }

    pub fn cols(&self) -> usize {
        self.term.grid().columns()
    }

    pub fn rows(&self) -> usize {
        self.term.grid().screen_lines()
    }

    pub fn write(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.term, bytes);
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        let size = TerminalSize {
            cols: cols.max(1),
            rows: rows.max(1),
        };
        self.term.resize(size);
    }

    pub fn scroll_view(&mut self, delta_lines: isize) {
        let delta = if delta_lines > i32::MAX as isize {
            i32::MAX
        } else if delta_lines < i32::MIN as isize {
            i32::MIN
        } else {
            delta_lines as i32
        };
        if delta != 0 {
            self.term.scroll_display(Scroll::Delta(delta));
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        self.term.scroll_display(Scroll::Bottom);
    }

    pub fn set_default_foreground(&mut self, foreground: u32) {
        if self.config.default_foreground != foreground {
            self.config.default_foreground = foreground;
            self.appearance_dirty = true;
        }
    }

    pub fn snapshot(&self) -> TerminalSnapshot {
        self.snapshot_with_dirty(Vec::new())
    }

    pub fn dirty_snapshot(&mut self) -> TerminalSnapshot {
        let dirty_rows = self.take_dirty_rows();
        self.snapshot_with_dirty(dirty_rows)
    }

    fn take_dirty_rows(&mut self) -> Vec<usize> {
        let rows = self.rows();
        let mut dirty_rows = if self.appearance_dirty {
            (0..rows).collect()
        } else {
            Vec::new()
        };

        {
            match self.term.damage() {
                TermDamage::Full => dirty_rows.extend(0..rows),
                TermDamage::Partial(lines) => {
                    dirty_rows.extend(lines.map(|line| line.line).filter(|line| *line < rows));
                }
            }
        }
        self.term.reset_damage();
        self.appearance_dirty = false;

        dirty_rows.sort_unstable();
        dirty_rows.dedup();
        dirty_rows
    }

    fn snapshot_with_dirty(&self, dirty_rows: Vec<usize>) -> TerminalSnapshot {
        let grid = self.term.grid();
        let screen_top = grid.history_size();
        let view_top = screen_top.saturating_sub(grid.display_offset());
        let cursor_point = grid.cursor.point;
        let cursor_y = cursor_point.line.0.max(0) as usize;
        let cursor_x = cursor_point.column.0;
        let expected_cells = self.cols().saturating_mul(self.rows());
        let mut cells = Vec::with_capacity(expected_cells);

        for indexed in grid.display_iter() {
            cells.push(self.snapshot_cell(indexed.cell));
        }
        while cells.len() < expected_cells {
            cells.push(SnapshotCell::blank(self.default_attrs()));
        }
        cells.truncate(expected_cells);

        let mode = *self.term.mode();
        TerminalSnapshot {
            cols: self.cols(),
            rows: self.rows(),
            cursor_x: cursor_x.min(self.cols().saturating_sub(1)),
            cursor_y: cursor_y.min(self.rows().saturating_sub(1)),
            cursor_visible: mode.contains(TermMode::SHOW_CURSOR),
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE),
            mouse_tracking: mouse_tracking_mode(mode),
            sgr_mouse: mode.contains(TermMode::SGR_MOUSE),
            application_cursor_keys: mode.contains(TermMode::APP_CURSOR),
            application_keypad: mode.contains(TermMode::APP_KEYPAD),
            auto_wrap: mode.contains(TermMode::LINE_WRAP),
            view_top,
            screen_top,
            is_at_bottom: grid.display_offset() == 0,
            dirty_rows,
            cells,
        }
    }

    fn default_attrs(&self) -> CellAttrs {
        CellAttrs {
            fg: self.config.default_foreground,
            bg: self.config.default_background,
            bold: false,
            italic: false,
            underline: false,
            inverse: false,
        }
    }

    fn snapshot_cell(&self, cell: &AlacrittyCell) -> SnapshotCell {
        let flags = cell.flags;
        let mut fg = self.resolve_color(cell.fg);
        if flags.contains(Flags::DIM) {
            fg = dim_color(fg);
        }
        SnapshotCell {
            ch: cell.c,
            fg,
            bg: self.resolve_color(cell.bg),
            bold: flags.contains(Flags::BOLD),
            italic: flags.contains(Flags::ITALIC),
            underline: flags.intersects(Flags::ALL_UNDERLINES),
            inverse: flags.contains(Flags::INVERSE),
            wide: flags.contains(Flags::WIDE_CHAR),
            wide_continuation: flags.contains(Flags::WIDE_CHAR_SPACER),
        }
    }

    fn resolve_color(&self, color: Color) -> u32 {
        match color {
            Color::Spec(rgb) => rgb_to_argb(rgb),
            Color::Indexed(index) => xterm_256_color(index as u16),
            Color::Named(named) => match named {
                NamedColor::Foreground => self.config.default_foreground,
                NamedColor::Background => self.config.default_background,
                NamedColor::Cursor | NamedColor::BrightForeground => {
                    brighten_color(self.config.default_foreground)
                }
                NamedColor::DimForeground => dim_color(self.config.default_foreground),
                NamedColor::Black
                | NamedColor::Red
                | NamedColor::Green
                | NamedColor::Yellow
                | NamedColor::Blue
                | NamedColor::Magenta
                | NamedColor::Cyan
                | NamedColor::White
                | NamedColor::BrightBlack
                | NamedColor::BrightRed
                | NamedColor::BrightGreen
                | NamedColor::BrightYellow
                | NamedColor::BrightBlue
                | NamedColor::BrightMagenta
                | NamedColor::BrightCyan
                | NamedColor::BrightWhite => xterm_256_color(named as u16),
                NamedColor::DimBlack => dim_color(xterm_256_color(0)),
                NamedColor::DimRed => dim_color(xterm_256_color(1)),
                NamedColor::DimGreen => dim_color(xterm_256_color(2)),
                NamedColor::DimYellow => dim_color(xterm_256_color(3)),
                NamedColor::DimBlue => dim_color(xterm_256_color(4)),
                NamedColor::DimMagenta => dim_color(xterm_256_color(5)),
                NamedColor::DimCyan => dim_color(xterm_256_color(6)),
                NamedColor::DimWhite => dim_color(xterm_256_color(7)),
            },
        }
    }
}

fn mouse_tracking_mode(mode: TermMode) -> u16 {
    if mode.contains(TermMode::MOUSE_MOTION) {
        1003
    } else if mode.contains(TermMode::MOUSE_DRAG) {
        1002
    } else if mode.contains(TermMode::MOUSE_REPORT_CLICK) {
        1000
    } else {
        0
    }
}

fn rgb_to_argb(rgb: Rgb) -> u32 {
    0xFF00_0000 | ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | rgb.b as u32
}

fn dim_color(color: u32) -> u32 {
    let r = ((color >> 16) & 0xFF) * 2 / 3;
    let g = ((color >> 8) & 0xFF) * 2 / 3;
    let b = (color & 0xFF) * 2 / 3;
    0xFF00_0000 | (r << 16) | (g << 8) | b
}

fn brighten_color(color: u32) -> u32 {
    let brighten = |channel: u32| channel + (255 - channel) / 3;
    let r = brighten((color >> 16) & 0xFF);
    let g = brighten((color >> 8) & 0xFF);
    let b = brighten(color & 0xFF);
    0xFF00_0000 | (r << 16) | (g << 8) | b
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen_text(term: &AlacrittyTerminal) -> Vec<String> {
        let snapshot = term.snapshot();
        snapshot
            .cells
            .chunks(snapshot.cols)
            .map(|row| row.iter().map(|cell| cell.ch).collect())
            .collect()
    }

    #[test]
    fn writes_plain_text_and_reports_damage() {
        let mut term = AlacrittyTerminal::new(8, 3, AlacrittyTerminalConfig::default());
        term.write(b"hello");

        let rows = screen_text(&term);
        assert_eq!(&rows[0][..5], "hello");
        assert_eq!(term.snapshot().cursor_x, 5);
        assert!(!term.dirty_snapshot().dirty_rows.is_empty());
    }

    #[test]
    fn ansi_colors_are_kept_separate_from_the_default_foreground() {
        let config = AlacrittyTerminalConfig {
            default_foreground: 0xFF33_FF33,
            ..AlacrittyTerminalConfig::default()
        };
        let mut term = AlacrittyTerminal::new(8, 2, config);
        term.write(b"\x1b[31mR\x1b[0mN");

        let snapshot = term.snapshot();
        assert_ne!(snapshot.cells[0].fg, config.default_foreground);
        assert_eq!(snapshot.cells[1].fg, config.default_foreground);
    }

    #[test]
    fn foreground_setting_updates_existing_default_cells_inside_the_core() {
        let mut term = AlacrittyTerminal::new(8, 2, AlacrittyTerminalConfig::default());
        term.write(b"N");
        term.set_default_foreground(0xFF11_2233);

        let snapshot = term.dirty_snapshot();
        assert_eq!(snapshot.cells[0].fg, 0xFF11_2233);
        assert_eq!(snapshot.dirty_rows, vec![0, 1]);
    }

    #[test]
    fn alternate_screen_restores_primary_content() {
        let mut term = AlacrittyTerminal::new(8, 2, AlacrittyTerminalConfig::default());
        term.write(b"main");
        term.write(b"\x1b[?1049h\x1b[2Jalt\x1b[?1049l");

        let rows = screen_text(&term);
        assert_eq!(&rows[0][..4], "main");
    }

    #[test]
    fn resize_and_scrollback_use_the_existing_snapshot_coordinates() {
        let mut term = AlacrittyTerminal::new(4, 2, AlacrittyTerminalConfig::default());
        term.write(b"1\r\n2\r\n3");

        let bottom = term.snapshot();
        assert_eq!(bottom.screen_top, 1);
        assert_eq!(bottom.view_top, bottom.screen_top);
        assert_eq!(&screen_text(&term)[0][..1], "2");

        term.scroll_view(1);
        let history = term.snapshot();
        assert_eq!(history.view_top, 0);
        assert_eq!(&screen_text(&term)[0][..1], "1");

        term.resize(6, 3);
        let resized = term.snapshot();
        assert_eq!(resized.cols, 6);
        assert_eq!(resized.rows, 3);
    }
}
