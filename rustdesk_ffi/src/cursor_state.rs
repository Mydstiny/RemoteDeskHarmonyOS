use crate::protocol::message_proto::CursorData;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::Read;

const MAX_CURSOR_DIMENSION: i32 = 384;
// Keep the protocol-ID cache bounded without imposing an arbitrary shape
// count. The budget is charged against the compressed protocol payload, not
// the decoded RGBA copy. A 32 MiB budget therefore holds many more normal
// cursors during a long session, while the currently selected shape is never
// evicted.
const MAX_CURSOR_CACHE_BYTES: usize = 32 * 1024 * 1024;
const MAX_EVICTION_HISTORY: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CursorShape {
    pub id: u64,
    pub hot_x: i32,
    pub hot_y: i32,
    pub width: i32,
    pub height: i32,
    pub rgba: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CursorCacheEntry {
    id: u64,
    hot_x: i32,
    hot_y: i32,
    width: i32,
    height: i32,
    compressed_colors: Vec<u8>,
}

impl CursorCacheEntry {
    fn expected_rgba_len(&self) -> usize {
        self.width as usize * self.height as usize * 4
    }
}

pub(crate) struct CursorState {
    // RustDesk cursor ids are stable protocol identities.  A small FIFO is
    // incorrect here: switching between more than four normal Windows
    // cursors would evict a still-valid shape and make the next CursorId
    // indistinguishable from an out-of-order update.
    // Keep compressed colors for non-selected entries. The selected entry is
    // decoded once into selected_shape for the native callback, so switching
    // between cached IDs does not retain one full RGBA allocation per shape.
    shapes: HashMap<u64, CursorCacheEntry>,
    shape_order: VecDeque<u64>,
    cached_bytes: usize,
    cache_budget_bytes: usize,
    evicted_ids: VecDeque<u64>,
    selected_id: Option<u64>,
    selected_shape: Option<CursorShape>,
    position: Option<(i32, i32)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CursorCacheMissReason {
    PendingOrUnknown,
    BudgetEvicted,
    CorruptCachedShape,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CursorIdResult {
    Selected(CursorShape),
    CacheMiss {
        id: u64,
        reason: CursorCacheMissReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CursorStreamUpdate {
    Shape(CursorShape),
    Position { x: i32, y: i32 },
    Visibility(bool),
    /** The requested shape is not present. Keep the previous shape visible. */
    CacheMiss {
        id: u64,
        reason: CursorCacheMissReason,
    },
}

impl CursorState {
    pub(crate) fn new() -> Self {
        Self::with_cache_budget(MAX_CURSOR_CACHE_BYTES)
    }

    fn with_cache_budget(cache_budget_bytes: usize) -> Self {
        Self {
            shapes: HashMap::new(),
            shape_order: VecDeque::new(),
            cached_bytes: 0,
            cache_budget_bytes,
            evicted_ids: VecDeque::new(),
            selected_id: None,
            selected_shape: None,
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
        let compressed_colors = data.get_colors().to_vec();
        if compressed_colors.is_empty() || compressed_colors.len() > MAX_CURSOR_CACHE_BYTES {
            return false;
        }
        let Some(rgba) = Self::decode_colors(&compressed_colors, expected_len) else {
            return false;
        };

        let id = data.get_id();
        if let Some(previous) = self.shapes.remove(&id) {
            self.cached_bytes = self
                .cached_bytes
                .saturating_sub(previous.compressed_colors.len());
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
        let entry = CursorCacheEntry {
            id,
            hot_x,
            hot_y,
            width,
            height,
            compressed_colors,
        };
        self.cached_bytes = self
            .cached_bytes
            .saturating_add(entry.compressed_colors.len());
        self.shapes.insert(id, entry);
        self.shape_order.push_back(id);
        // RustDesk sends CursorData the first time a shape is seen and does
        // not have to follow it with CursorId.  The newly decoded shape is
        // therefore the active shape for this stream.
        self.selected_id = Some(id);
        self.selected_shape = Some(shape);
        self.remove_eviction_history(id);
        self.trim_cache();
        true
    }

    pub(crate) fn apply_id(&mut self, id: u64) -> CursorIdResult {
        let Some(entry) = self.shapes.get(&id).cloned() else {
            // A CursorId can race with a delayed CursorData or arrive after a
            // reconnect.  Never replace a valid selection with a missing id:
            // doing so leaves the UI without a shape revision and it keeps
            // presenting an unrelated/stale cursor forever.
            let reason = if self.evicted_ids.contains(&id) {
                CursorCacheMissReason::BudgetEvicted
            } else {
                CursorCacheMissReason::PendingOrUnknown
            };
            return CursorIdResult::CacheMiss { id, reason };
        };
        let Some(rgba) = Self::decode_colors(&entry.compressed_colors, entry.expected_rgba_len())
        else {
            // A cached entry is created only after validation, but keep the
            // failure path bounded if memory corruption or a future cache
            // format change makes the payload undecodable. The previous shape
            // remains selected and visible.
            self.remove_cached_entry(id);
            return CursorIdResult::CacheMiss {
                id,
                reason: CursorCacheMissReason::CorruptCachedShape,
            };
        };
        let shape = CursorShape {
            id: entry.id,
            hot_x: entry.hot_x,
            hot_y: entry.hot_y,
            width: entry.width,
            height: entry.height,
            rgba,
        };
        self.selected_id = Some(id);
        self.selected_shape = Some(shape.clone());
        self.touch_shape(id);
        CursorIdResult::Selected(shape)
    }

    pub(crate) fn current_shape(&self) -> Option<&CursorShape> {
        self.selected_shape.as_ref()
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

    fn remove_cached_entry(&mut self, id: u64) {
        if let Some(entry) = self.shapes.remove(&id) {
            self.cached_bytes = self
                .cached_bytes
                .saturating_sub(entry.compressed_colors.len());
            self.remove_from_order(id);
        }
    }

    fn remove_eviction_history(&mut self, id: u64) {
        if let Some(index) = self.evicted_ids.iter().position(|candidate| *candidate == id) {
            self.evicted_ids.remove(index);
        }
    }

    fn record_eviction(&mut self, id: u64) {
        self.remove_eviction_history(id);
        self.evicted_ids.push_back(id);
        while self.evicted_ids.len() > MAX_EVICTION_HISTORY {
            self.evicted_ids.pop_front();
        }
    }

    fn decode_colors(compressed_colors: &[u8], expected_len: usize) -> Option<Vec<u8>> {
        let decoder = zstd::stream::read::Decoder::new(compressed_colors).ok()?;
        let mut rgba = Vec::with_capacity(expected_len.min(4096));
        if decoder
            .take(expected_len as u64 + 1)
            .read_to_end(&mut rgba)
            .is_err()
            || rgba.len() != expected_len
        {
            return None;
        }
        Some(rgba)
    }

    fn trim_cache(&mut self) {
        while self.cached_bytes > self.cache_budget_bytes {
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
                self.cached_bytes = self
                    .cached_bytes
                    .saturating_sub(evicted.compressed_colors.len());
                self.record_eviction(id);
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
        assert!(matches!(
            state.apply_id(42),
            CursorIdResult::CacheMiss {
                id: 42,
                reason: CursorCacheMissReason::PendingOrUnknown
            }
        ));
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

    #[test]
    fn budget_eviction_is_diagnostic_only_and_preserves_last_shape() {
        let mut state = CursorState::with_cache_budget(1);
        assert!(state.apply_data(cursor_data(1, 0, 0, 1, 1, vec![1; 4])));
        assert!(state.apply_data(cursor_data(2, 0, 0, 1, 1, vec![2; 4])));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(2));

        assert!(matches!(
            state.apply_id(1),
            CursorIdResult::CacheMiss {
                id: 1,
                reason: CursorCacheMissReason::BudgetEvicted
            }
        ));
        assert!(matches!(
            state.apply_id(999),
            CursorIdResult::CacheMiss {
                id: 999,
                reason: CursorCacheMissReason::PendingOrUnknown
            }
        ));
        assert_eq!(state.current_shape().map(|shape| shape.id), Some(2));
    }
}
