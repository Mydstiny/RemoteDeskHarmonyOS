use crate::protocol::message_proto::CursorData;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::Read;

const MAX_CURSOR_DIMENSION: i32 = 384;
// Keep the protocol-ID cache bounded without imposing an arbitrary shape
// count. A 32 MiB budget holds dozens of large cursors and is only reached by
// a peer that continuously creates new bitmaps; the currently selected shape
// is never evicted.
const MAX_CURSOR_CACHE_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CursorShape {
    pub id: u64,
    pub hot_x: i32,
    pub hot_y: i32,
    pub width: i32,
    pub height: i32,
    pub rgba: Vec<u8>,
}

pub(crate) struct CursorState {
    // RustDesk cursor ids are stable protocol identities.  A small FIFO is
    // incorrect here: switching between more than four normal Windows
    // cursors would evict a still-valid shape and make the next CursorId
    // indistinguishable from an out-of-order update.
    shapes: HashMap<u64, CursorShape>,
    shape_order: VecDeque<u64>,
    cached_bytes: usize,
    selected_id: Option<u64>,
    position: Option<(i32, i32)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CursorIdResult {
    Selected(CursorShape),
    CacheMiss { id: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CursorStreamUpdate {
    Shape(CursorShape),
    Position { x: i32, y: i32 },
    Visibility(bool),
    /** The requested shape is not present. Keep the previous shape visible. */
    CacheMiss { id: u64 },
}

impl CursorState {
    pub(crate) fn new() -> Self {
        Self {
            shapes: HashMap::new(),
            shape_order: VecDeque::new(),
            cached_bytes: 0,
            selected_id: None,
            position: None,
        }
    }

    pub(crate) fn apply_data(&mut self, data: CursorData) -> bool {
        let width = data.get_width();
        let height = data.get_height();
        let hot_x = data.get_hotx();
        let hot_y = data.get_hoty();
        if width <= 0
            || height <= 0
            || width > MAX_CURSOR_DIMENSION
            || height > MAX_CURSOR_DIMENSION
            || hot_x < 0
            || hot_y < 0
            || hot_x >= width
            || hot_y >= height
        {
            return false;
        }

        let expected_len = width as usize * height as usize * 4;
        let decoder = match zstd::stream::read::Decoder::new(data.get_colors()) {
            Ok(decoder) => decoder,
            Err(_) => return false,
        };
        let mut rgba = Vec::with_capacity(expected_len.min(4096));
        if decoder
            .take(expected_len as u64 + 1)
            .read_to_end(&mut rgba)
            .is_err()
            || rgba.len() != expected_len
        {
            return false;
        }

        let id = data.get_id();
        if let Some(previous) = self.shapes.remove(&id) {
            self.cached_bytes = self.cached_bytes.saturating_sub(previous.rgba.len());
            self.remove_from_order(id);
        }
        let shape = CursorShape {
            id,
            hot_x,
            hot_y,
            width,
            height,
            rgba,
        };
        self.cached_bytes = self.cached_bytes.saturating_add(shape.rgba.len());
        self.shapes.insert(id, shape);
        self.shape_order.push_back(id);
        // RustDesk sends CursorData the first time a shape is seen and does
        // not have to follow it with CursorId.  The newly decoded shape is
        // therefore the active shape for this stream.
        self.selected_id = Some(id);
        self.trim_cache();
        true
    }

    pub(crate) fn apply_id(&mut self, id: u64) -> CursorIdResult {
        let Some(shape) = self.shapes.get(&id).cloned() else {
            // A CursorId can race with a delayed CursorData or arrive after a
            // reconnect.  Never replace a valid selection with a missing id:
            // doing so leaves the UI without a shape revision and it keeps
            // presenting an unrelated/stale cursor forever.
            return CursorIdResult::CacheMiss { id };
        };
        self.selected_id = Some(id);
        self.touch_shape(id);
        CursorIdResult::Selected(shape)
    }

    pub(crate) fn current_shape(&self) -> Option<&CursorShape> {
        let id = self.selected_id?;
        self.shapes.get(&id)
    }

    pub(crate) fn apply_position(&mut self, x: i32, y: i32) -> bool {
        let next = (x, y);
        if self.position == Some(next) {
            return false;
        }
        self.position = Some(next);
        true
    }

    pub(crate) fn position(&self) -> (i32, i32) {
        self.position.unwrap_or((0, 0))
    }

    fn remove_from_order(&mut self, id: u64) {
        if let Some(index) = self.shape_order.iter().position(|candidate| *candidate == id) {
            self.shape_order.remove(index);
        }
    }

    fn touch_shape(&mut self, id: u64) {
        self.remove_from_order(id);
        self.shape_order.push_back(id);
    }

    fn trim_cache(&mut self) {
        while self.cached_bytes > MAX_CURSOR_CACHE_BYTES {
            let Some(id) = self.shape_order.pop_front() else {
                break;
            };
            if self.selected_id == Some(id) {
                self.shape_order.push_back(id);
                // The selected shape is guaranteed to be below the budget by
                // the dimension limit. If this guard ever changes, retain it
                // rather than violating the last-valid-shape invariant.
                break;
            }
            if let Some(evicted) = self.shapes.remove(&id) {
                self.cached_bytes = self.cached_bytes.saturating_sub(evicted.rgba.len());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::message_proto::CursorData;

    fn cursor_data(id: u64, hot_x: i32, hot_y: i32, width: i32, height: i32,
                   rgba: Vec<u8>) -> CursorData {
        let mut data = CursorData::new();
        data.set_id(id);
        data.set_hotx(hot_x);
        data.set_hoty(hot_y);
        data.set_width(width);
        data.set_height(height);
        data.set_colors(zstd::encode_all(rgba.as_slice(), 0).expect("compress cursor"));
        data
    }

    #[test]
    fn cursor_id_selects_cached_shape_and_preserves_hotspot() {
        let mut state = CursorState::new();
        assert!(state.apply_data(cursor_data(7, 2, 3, 16, 16, vec![255; 1024])));
        assert!(matches!(state.apply_id(7), CursorIdResult::Selected(_)));
        let shape = state.current_shape().expect("selected shape");
        assert_eq!((shape.hot_x, shape.hot_y), (2, 3));
        assert_eq!((shape.width, shape.height), (16, 16));
        assert_eq!(shape.rgba.len(), 1024);
    }

    #[test]
    fn malformed_or_oversized_cursor_is_rejected() {
        let mut state = CursorState::new();
        assert!(!state.apply_data(cursor_data(1, 0, 0, 16, 16, vec![0; 3])));
        assert!(!state.apply_data(cursor_data(2, 0, 0, 385, 1, vec![0; 1540])));
        assert!(!state.apply_data(cursor_data(3, 1, 0, 1, 1, vec![0; 4])));
        assert!(state.current_shape().is_none());
    }

    #[test]
    fn cache_retains_all_protocol_cursor_ids_for_the_session() {
        let mut state = CursorState::new();
        for id in 1..=6 {
            assert!(state.apply_data(cursor_data(id, 0, 0, 1, 1, vec![id as u8; 4])));
        }
        // The old four-entry FIFO evicted id 1 here. Protocol IDs remain
        // selectable after a longer sequence and a round trip to the first
        // shape.
        for id in 1..=6 {
            assert!(matches!(state.apply_id(id), CursorIdResult::Selected(_)));
        }
    }

    #[test]
    fn cursor_position_changes_only_for_new_coordinates() {
        let mut state = CursorState::new();
        assert!(state.apply_position(100, 200));
        assert!(!state.apply_position(100, 200));
        assert_eq!(state.position(), (100, 200));
    }

    #[test]
    fn cursor_data_activates_when_id_arrived_before_shape() {
        let mut state = CursorState::new();
        assert!(state.apply_data(cursor_data(7, 0, 0, 1, 1, vec![1; 4])));
        assert!(matches!(state.apply_id(42), CursorIdResult::CacheMiss { id: 42 }));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(7));
        assert!(state.apply_data(cursor_data(42, 1, 1, 2, 2, vec![9; 16])));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(42));
    }

    #[test]
    fn cursor_data_selects_new_shape_without_followup_id() {
        let mut state = CursorState::new();
        assert!(state.apply_data(cursor_data(1, 0, 0, 1, 1, vec![1; 4])));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(1));

        // The official RustDesk server sends CursorData the first time a new
        // shape is seen and may not follow it with a separate CursorId.
        assert!(state.apply_data(cursor_data(2, 0, 0, 1, 1, vec![2; 4])));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(2));
    }
}
