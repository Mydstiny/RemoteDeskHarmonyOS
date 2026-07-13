# SSH Terminal Regression Test Cases

This checklist is the baseline for the SSH terminal native-core migration.
The current ArkTS terminal remains the fallback until the Rust core passes these cases.

## Scope

- Page: `entry/src/main/ets/pages/SshTerminal.ets`
- Current renderer: `entry/src/main/ets/components/TerminalEmulator.ets`
- Future core: `rustdesk_ffi/src/terminal_core/`

## Manual Cases

### T01 Basic Echo

Steps:

1. Open an SSH session.
2. Run `pwd`.
3. Run `ls`.
4. Run `ls` again.

Expected:

- Each command appears once.
- The second `ls` must not display as `lsls`.
- Cursor stays at the shell prompt after command output.

Failure signs:

- Hidden input buffer accumulates text.
- Prompt line contains duplicated user input.

### T02 Backspace And Re-entry

Steps:

1. Type `abc`.
2. Press Backspace twice.
3. Type `d`.
4. Press Enter.

Expected:

- Remote shell receives `ad`.
- Local terminal display matches the remote echo.
- No stale characters remain after deletion.

Failure signs:

- Display shows `abcd`, `abd`, or duplicated deletes.
- Local input and remote echo diverge.

### T03 Long Output

Steps:

1. Run `seq 1 1000`.
2. Watch output until completion.

Expected:

- Output remains responsive.
- Latest line stays visible when the viewport is at bottom.
- No per-line flicker or visible full-screen repaint.

Failure signs:

- UI stalls during output.
- Latest prompt falls behind the virtual key bar.

### T04 Clear Screen

Steps:

1. Run several commands.
2. Run `clear`.

Expected:

- Visible screen is cleared.
- Cursor returns to the top-left shell-controlled position.
- Scrollback behavior follows terminal semantics.

Failure signs:

- Old cells remain visible.
- Cursor is drawn over stale content.

### T05 ANSI Color

Steps:

1. Run `ls --color=always` or `grep --color=always root /etc/passwd`.

Expected:

- Colored spans render without corrupting plain text.
- Reset sequences restore default colors.

Failure signs:

- Escape sequences appear as text.
- Color leaks into later prompt lines.

### T06 Cursor Motion / Dynamic Output

Steps:

1. Run a command that updates the same line, such as a progress command.
2. If available, run `top` or a similar full-screen program.

Expected:

- Cursor movement updates the intended cells.
- Repeated refresh does not leave old cursor fragments.

Failure signs:

- Cursor remnants appear under multiple characters.
- Full-screen output shifts incorrectly.

### T07 PC Wheel Scroll

Steps:

1. Produce long output with `seq 1 1000`.
2. Use the mouse wheel to scroll upward.
3. Trigger new remote output.

Expected:

- Wheel changes only the local scrollback viewport.
- Remote cursor model does not move.
- Cursor is drawn only when its real screen row is visible.

Failure signs:

- Cursor jumps to the viewed history area.
- New output paints over historical rows.

### T08 Pad Portrait Keyboard

Steps:

1. Open SSH on a Pad in portrait.
2. Tap terminal to raise the software keyboard.
3. Run `ls`.

Expected:

- Virtual key bar bottom touches the keyboard top.
- Terminal visible bottom touches the virtual key bar top.
- Latest prompt remains visible.

Failure signs:

- Black gap appears between key bar and keyboard.
- Latest output is hidden behind the key bar or keyboard.

### T09 Pad Landscape Keyboard

Steps:

1. Open SSH on a Pad in landscape.
2. Raise the software keyboard.
3. Run `seq 1 100`.

Expected:

- Page itself does not scroll.
- Terminal rows shrink to the available height.
- Latest line remains immediately above the virtual key bar.

Failure signs:

- Whole page scrolls.
- Terminal content disappears behind the keyboard.
- A hard minimum row count forces overlap.

### T10 Phone Portrait Keyboard

Steps:

1. Open SSH on a phone in portrait.
2. Raise the software keyboard.
3. Type, delete, paste, and run a command.

Expected:

- Key bar avoids the system navigation area when keyboard is hidden.
- Key bar follows the keyboard top when keyboard is visible.
- Text input does not duplicate or retain stale text.

Failure signs:

- Buttons overlap the system navigation bar.
- Pasted text remains in the hidden `TextInput`.

## Automated Rust Core Cases

These cases belong in `rustdesk_ffi/src/terminal_core/tests.rs`.

- Plain text writes fill cells in order.
- `\n` moves to the next row.
- `\r` returns to column zero.
- Backspace moves the cursor left without underflow.
- `ESC[2J` clears visible cells and resets scrollback baseline.
- SGR color sequences update cell attributes and reset correctly.
- Writing past the bottom scrolls the active screen.
- User scroll changes `view_top` but not `screen_top` or cursor position.
- New output follows bottom only when `is_at_bottom` is true.
- Resize clamps cursor and preserves bottom-following behavior.
