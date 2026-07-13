pub const DEFAULT_FG: u32 = 0xFFE8EAED;
pub const DEFAULT_BG: u32 = 0xFF0B0F14;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CellAttrs {
    pub fg: u32,
    pub bg: u32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

impl Default for CellAttrs {
    fn default() -> Self {
        Self {
            fg: DEFAULT_FG,
            bg: DEFAULT_BG,
            bold: false,
            italic: false,
            underline: false,
            inverse: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cell {
    pub ch: char,
    pub attrs: CellAttrs,
    pub wide: bool,
    pub wide_continuation: bool,
}

impl Cell {
    pub fn blank(attrs: CellAttrs) -> Self {
        Self {
            ch: ' ',
            attrs,
            wide: false,
            wide_continuation: false,
        }
    }
}

/// xterm 256 色 → ARGB 颜色值
///
/// 调色板布局:
///   0-15:   标准 ANSI 色 (复用 ansi_color 映射)
///   16-231: 6×6×6 RGB 立方体 (每个通道 0/51/102/153/204/255)
///   232-255: 24 级灰度 (8, 18, 28, ..., 238)
pub fn xterm_256_color(index: u16) -> u32 {
    match index {
        0..=15 => {
            // 标准 ANSI 色 — 复用 terminal.rs 的色表逻辑
            const NORMAL: [u32; 8] = [
                0xFF1F2328, 0xFFFF5F57, 0xFF5AF78E, 0xFFF3F99D, 0xFF57C7FF, 0xFFFF6AC1, 0xFF9AEDFE,
                0xFFE8EAED,
            ];
            const BRIGHT: [u32; 8] = [
                0xFF6E7681, 0xFFFF7B72, 0xFF7EE787, 0xFFFFD866, 0xFF79C0FF, 0xFFD2A8FF, 0xFFA5F3FC,
                0xFFFFFFFF,
            ];
            let idx = (index & 7) as usize;
            if index >= 8 {
                BRIGHT[idx]
            } else {
                NORMAL[idx]
            }
        }
        16..=231 => {
            let idx = index - 16;
            let r = (idx / 36) * 51; // 6 级红色
            let g = ((idx / 6) % 6) * 51; // 6 级绿色
            let b = (idx % 6) * 51; // 6 级蓝色
            (0xFF << 24) | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32)
        }
        232..=255 => {
            let level = ((index - 232) * 10 + 8) as u32;
            (0xFF << 24) | (level << 16) | (level << 8) | level
        }
        _ => DEFAULT_FG, // 超出范围回退默认前景色
    }
}
