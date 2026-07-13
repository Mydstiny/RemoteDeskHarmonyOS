use vte::{Params, Perform};

use super::terminal::Terminal;

/// 稀疏采样阈值: 前 N 次全部打印, 之后每 SAMPLE_EVERY 次打印一次
const SAMPLE_FIRST_N: usize = 5;
const SAMPLE_EVERY: usize = 100;

pub struct TerminalPerformer<'a> {
    terminal: &'a mut Terminal,
    unknown_csi_count: usize,
    unknown_esc_count: usize,
    unknown_priv_mode_count: usize,
}

impl<'a> TerminalPerformer<'a> {
    pub fn new(terminal: &'a mut Terminal) -> Self {
        Self {
            terminal,
            unknown_csi_count: 0,
            unknown_esc_count: 0,
            unknown_priv_mode_count: 0,
        }
    }

    fn should_log(cnt: &mut usize) -> bool {
        *cnt += 1;
        *cnt <= SAMPLE_FIRST_N || (*cnt % SAMPLE_EVERY == 0)
    }

    fn log_unknown_csi(&mut self, action: char, params: &Params, extra: &str) {
        if Self::should_log(&mut self.unknown_csi_count) {
            let p: Vec<String> = params
                .iter()
                .map(|sub| {
                    sub.iter()
                        .map(|v| v.to_string())
                        .collect::<Vec<_>>()
                        .join(";")
                })
                .collect();
            eprintln!(
                "[terminal_core] unknown CSI {}{} #{} params=[{}]",
                action,
                extra,
                self.unknown_csi_count,
                p.join(";")
            );
        }
    }

    fn log_unknown_esc(&mut self, byte: u8) {
        if Self::should_log(&mut self.unknown_esc_count) {
            eprintln!(
                "[terminal_core] unknown ESC 0x{:02X} ('{}') #{}",
                byte,
                if byte.is_ascii_graphic() || byte == b' ' {
                    byte as char
                } else {
                    '?'
                },
                self.unknown_esc_count,
            );
        }
    }

    /// 处理 DEC 私有模式设置 (DECSET, CSI ?...h)
    fn handle_private_set(&mut self, params: &Params) {
        let mode = param_or(params, 0, 0);
        match mode {
            25 => self.terminal.set_cursor_visible(true),
            1049 => {
                // 保存光标 + 进入备用屏并清屏
                self.terminal.save_cursor_full();
                self.terminal.enter_alt_screen(true);
                eprintln!("[terminal_core] alternate screen ENTER (?1049h)");
            }
            47 => {
                self.terminal.enter_alt_screen(false);
                eprintln!("[terminal_core] alternate screen ENTER (?47h)");
            }
            1047 => {
                self.terminal.enter_alt_screen(true);
                eprintln!("[terminal_core] alternate screen ENTER (?1047h)");
            }
            1048 => {
                self.terminal.save_cursor_full();
            }
            2004 => {
                // Bracketed paste — 安全记录, 不处理
                eprintln!("[terminal_core] bracketed paste mode ON (?2004h) — ignored");
            }
            7 => {
                // Autowrap — 安全记录
                eprintln!("[terminal_core] auto-wrap ON (?7h) — ignored");
            }
            1000 | 1002 | 1006 => {
                // 鼠标追踪 — 安全忽略
                eprintln!(
                    "[terminal_core] mouse tracking mode ON (?{}h) — ignored",
                    mode
                );
            }
            12 => {
                // 光标闪烁 — 安全忽略
            }
            _ => {
                if Self::should_log(&mut self.unknown_priv_mode_count) {
                    eprintln!(
                        "[terminal_core] unknown DECSET ?{}h #{}",
                        mode, self.unknown_priv_mode_count
                    );
                }
            }
        }
    }

    /// 处理 DEC 私有模式重置 (DECRST, CSI ?...l)
    fn handle_private_reset(&mut self, params: &Params) {
        let mode = param_or(params, 0, 0);
        match mode {
            25 => self.terminal.set_cursor_visible(false),
            1049 => {
                self.terminal.leave_alt_screen(true);
                self.terminal.restore_cursor_full();
                eprintln!("[terminal_core] alternate screen LEAVE (?1049l)");
            }
            47 => {
                self.terminal.leave_alt_screen(false);
                eprintln!("[terminal_core] alternate screen LEAVE (?47l)");
            }
            1047 => {
                self.terminal.leave_alt_screen(false);
                eprintln!("[terminal_core] alternate screen LEAVE (?1047l)");
            }
            1048 => {
                self.terminal.restore_cursor_full();
            }
            2004 => {
                eprintln!("[terminal_core] bracketed paste mode OFF (?2004l)");
            }
            7 => {
                eprintln!("[terminal_core] auto-wrap OFF (?7l)");
            }
            1000 | 1002 | 1006 => {
                eprintln!("[terminal_core] mouse tracking mode OFF (?{}l)", mode);
            }
            12 => {
                // 光标闪烁 — 安全忽略
            }
            _ => {
                if Self::should_log(&mut self.unknown_priv_mode_count) {
                    eprintln!(
                        "[terminal_core] unknown DECRST ?{}l #{}",
                        mode, self.unknown_priv_mode_count
                    );
                }
            }
        }
    }
}

impl Perform for TerminalPerformer<'_> {
    fn print(&mut self, c: char) {
        self.terminal.print_char(c);
    }

    fn execute(&mut self, byte: u8) {
        self.terminal.execute_byte(byte);
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // 检查是否为 DEC 私有模式 (intermediate = ?)
        let is_private = intermediates == b"?";
        match action {
            'A' => self
                .terminal
                .move_cursor(0, -(param_or(params, 0, 1) as isize)),
            'B' => self
                .terminal
                .move_cursor(0, param_or(params, 0, 1) as isize),
            'C' => self
                .terminal
                .move_cursor(param_or(params, 0, 1) as isize, 0),
            'D' => self
                .terminal
                .move_cursor(-(param_or(params, 0, 1) as isize), 0),
            'E' => {
                // CNL — Cursor Next Line
                let n = param_or(params, 0, 1) as usize;
                self.terminal.cursor_next_line(n);
            }
            'F' => {
                // CPL — Cursor Previous Line
                let n = param_or(params, 0, 1) as usize;
                self.terminal.cursor_prev_line(n);
            }
            'G' => {
                // CHA — Cursor Horizontal Absolute
                let col = param_or(params, 0, 1) as usize;
                self.terminal.cursor_absolute_col(col);
            }
            'H' | 'f' => {
                let row = param_or(params, 0, 1).saturating_sub(1) as usize;
                let col = param_or(params, 1, 1).saturating_sub(1) as usize;
                self.terminal.set_cursor(col, row);
            }
            'J' => {
                if is_private {
                    // CSI ?J — 私有模式清屏 (DECSED), 安全忽略
                    self.log_unknown_csi(action, params, " (private J)");
                } else {
                    match param_or(params, 0, 0) {
                        0 => self.terminal.clear_screen_from_cursor(),
                        1 => self.terminal.clear_screen_to_cursor(),
                        2 | 3 => self.terminal.clear_screen(),
                        _ => {}
                    }
                }
            }
            'K' => {
                if is_private {
                    // CSI ?K — 私有模式清行 (DECSEL), 安全忽略
                    self.log_unknown_csi(action, params, " (private K)");
                } else {
                    match param_or(params, 0, 0) {
                        0 => self.terminal.clear_line_from_cursor(),
                        1 => self.terminal.clear_line_to_cursor(),
                        2 => self.terminal.clear_line(),
                        _ => {}
                    }
                }
            }
            'L' => {
                // IL — Insert Lines
                let n = param_or(params, 0, 1) as usize;
                self.terminal.insert_lines(n);
            }
            'M' => {
                // DL — Delete Lines
                let n = param_or(params, 0, 1) as usize;
                self.terminal.delete_lines(n);
            }
            'P' => {
                // DCH — Delete Characters
                let n = param_or(params, 0, 1) as usize;
                self.terminal.delete_chars(n);
            }
            'X' => {
                // ECH — Erase Characters
                let n = param_or(params, 0, 1) as usize;
                self.terminal.erase_chars(n);
            }
            '@' => {
                // ICH — Insert Characters
                let n = param_or(params, 0, 1) as usize;
                self.terminal.insert_chars(n);
            }
            'd' => {
                // VPA — Vertical Position Absolute
                let row = param_or(params, 0, 1) as usize;
                self.terminal.cursor_absolute_row(row);
            }
            'h' => {
                if is_private {
                    self.handle_private_set(params);
                } else {
                    // ANSI mode set — 目前无需要处理的非私有模式
                    let mode = param_or(params, 0, 0);
                    self.log_unknown_csi(action, params, &format!(" (mode={})", mode));
                }
            }
            'l' => {
                if is_private {
                    self.handle_private_reset(params);
                } else {
                    // ANSI mode reset
                    let mode = param_or(params, 0, 0);
                    self.log_unknown_csi(action, params, &format!(" (mode={})", mode));
                }
            }
            'm' => {
                let sgr = collect_params(params);
                self.terminal.set_sgr(&sgr);
            }
            'r' => {
                // 滚动区域 (DECSTBM)
                if is_private {
                    self.log_unknown_csi(action, params, " (private r)");
                } else {
                    let top = params.iter().nth(0).and_then(|s| s.first().copied());
                    let bottom = params.iter().nth(1).and_then(|s| s.first().copied());
                    self.terminal
                        .set_scroll_region(top.map(|v| v as usize), bottom.map(|v| v as usize));
                    eprintln!(
                        "[terminal_core] scroll region set: top={:?} bottom={:?}",
                        top, bottom
                    );
                }
            }
            's' => {
                if is_private {
                    self.log_unknown_csi(action, params, " (private s)");
                } else {
                    // SCOSC — 保存光标位置 (仅位置, 不含属性)
                    self.terminal.save_cursor_pos();
                }
            }
            'u' => {
                if is_private {
                    self.log_unknown_csi(action, params, " (private u)");
                } else {
                    // SCORC — 恢复光标位置
                    self.terminal.restore_cursor_pos();
                }
            }
            _ => {
                self.log_unknown_csi(action, params, "");
            }
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        if !intermediates.is_empty() {
            eprintln!(
                "[terminal_core] ESC with intermediates 0x{:02X?} byte=0x{:02X} — ignored",
                intermediates, byte
            );
            return;
        }
        match byte {
            b'c' => {
                // RIS — 完全复位
                self.terminal.clear_screen();
            }
            b'7' => {
                // DECSC — 保存光标 (位置 + 属性)
                self.terminal.save_cursor_full();
            }
            b'8' => {
                // DECRC — 恢复光标
                self.terminal.restore_cursor_full();
            }
            b'M' => {
                // RI — 反向索引
                self.terminal.reverse_index();
            }
            b'(' | b')' => {
                // 字符集指定 G0/G1 — 安全忽略
            }
            b'>' => {
                // 正常小键盘模式 — 安全忽略
            }
            b'=' => {
                // 应用小键盘模式 — 安全忽略
            }
            b'H' => {
                // 水平制表位设置 — 安全忽略
            }
            _ => {
                self.log_unknown_esc(byte);
            }
        }
    }
}

fn param_or(params: &Params, index: usize, default: u16) -> u16 {
    let value = params
        .iter()
        .nth(index)
        .and_then(|subparams| subparams.first().copied())
        .unwrap_or(default);
    if default != 0 && value == 0 {
        default
    } else {
        value
    }
}

fn collect_params(params: &Params) -> Vec<u16> {
    let values: Vec<u16> = params
        .iter()
        .filter_map(|subparams| subparams.first().copied())
        .collect();
    if values.is_empty() {
        vec![0]
    } else {
        values
    }
}
