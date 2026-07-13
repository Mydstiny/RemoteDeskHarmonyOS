use super::cell::{Cell, CellAttrs};

pub type Row = Vec<Cell>;

pub fn blank_row(cols: usize, attrs: CellAttrs) -> Row {
    (0..cols).map(|_| Cell::blank(attrs)).collect()
}

pub fn resize_row(row: &mut Row, cols: usize, attrs: CellAttrs) {
    if row.len() < cols {
        row.extend((row.len()..cols).map(|_| Cell::blank(attrs)));
    } else if row.len() > cols {
        row.truncate(cols);
    }
}
