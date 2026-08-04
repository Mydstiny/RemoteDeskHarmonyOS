pub mod cell;
pub mod ffi;
pub mod grid;
pub mod parser;
pub mod snapshot;
pub mod terminal;

#[cfg(feature = "alacritty_terminal")]
pub mod alacritty_adapter;

pub use cell::{Cell, CellAttrs};
pub use snapshot::{SnapshotCell, TerminalSnapshot};
pub use terminal::Terminal;

#[cfg(feature = "alacritty_terminal")]
pub use alacritty_adapter::{AlacrittyTerminal, AlacrittyTerminalConfig};

#[cfg(test)]
mod tests;
