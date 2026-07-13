use super::cell::CellAttrs;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnapshotCell {
    pub ch: char,
    pub fg: u32,
    pub bg: u32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub wide: bool,
    pub wide_continuation: bool,
}

impl SnapshotCell {
    pub fn blank(attrs: CellAttrs) -> Self {
        Self {
            ch: ' ',
            fg: attrs.fg,
            bg: attrs.bg,
            bold: attrs.bold,
            italic: attrs.italic,
            underline: attrs.underline,
            inverse: attrs.inverse,
            wide: false,
            wide_continuation: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalSnapshot {
    pub cols: usize,
    pub rows: usize,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub cursor_visible: bool,
    pub view_top: usize,
    pub screen_top: usize,
    pub is_at_bottom: bool,
    pub dirty_rows: Vec<usize>,
    pub cells: Vec<SnapshotCell>,
}
