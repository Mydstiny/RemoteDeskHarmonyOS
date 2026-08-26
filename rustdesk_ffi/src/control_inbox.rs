use crate::ControlMsg;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;

pub(crate) const CONTROL_BATCH_LIMIT: usize = 8;
pub(crate) const PERMISSION_KEYBOARD: u32 = 1 << 0;
pub(crate) const PERMISSION_CLIPBOARD: u32 = 1 << 2;
pub(crate) const PERMISSION_AUDIO: u32 = 1 << 3;
pub(crate) const PERMISSION_FILE: u32 = 1 << 4;
pub(crate) const PERMISSION_RESTART: u32 = 1 << 5;
pub(crate) const PERMISSION_RECORDING: u32 = 1 << 6;
pub(crate) const PERMISSION_BLOCK_INPUT: u32 = 1 << 7;
pub(crate) const PERMISSION_PRIVACY_MODE: u32 = 1 << 8;
const TOUCH_SCALE_BASE: i128 = 1000;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct PermissionSnapshot {
    pub known_mask: u32,
    pub enabled_mask: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ControlInboxSnapshot {
    pub reliable_depth: usize,
    pub max_reliable_depth: usize,
    pub coalesced_mouse_moves: u64,
    pub coalesced_display_switches: u64,
    pub discarded_pointer_updates: u64,
    pub coalesced_refreshes: u64,
    pub coalesced_video_pressure: u64,
    pub coalesced_touch_scales: u64,
    pub coalesced_touch_pan_updates: u64,
    pub coalesced_mouse_wheel_2d: u64,
    pub touch_active: bool,
    pub touch_update_pending: bool,
    pub mouse_wheel_2d_pending: bool,
    pub touch_barrier_wait: bool,
    pub batch_limit_hits: u64,
}

pub(crate) struct ControlInbox {
    shutdown: AtomicBool,
    permission_known: AtomicU32,
    permission_enabled: AtomicU32,
    state: Mutex<ControlInboxState>,
}

struct SequencedControl {
    sequence: u64,
    message: ControlMsg,
}

struct PendingTouchUpdate {
    // The slot sequence advances with every update. A later reliable message
    // flushes this slot first, so the merged value never crosses that order
    // boundary.
    sequence: u64,
    scale: Option<i32>,
    pan: Option<(i32, i32)>,
}

impl PendingTouchUpdate {
    fn is_empty(&self) -> bool {
        self.scale.is_none() && self.pan.is_none()
    }
}

struct PendingMouseWheel2D {
    sequence: u64,
    x: i32,
    y: i32,
}

struct ControlInboxState {
    next_sequence: u64,
    reliable: VecDeque<SequencedControl>,
    display_switch: Option<SequencedControl>,
    // Mouse movement is still latest-value-wins, but it retains the sequence
    // at which that latest coordinate was observed. A click must not overtake
    // the movement that positions the remote macOS cursor over its target.
    mouse_move: Option<SequencedControl>,
    refresh_pending: bool,
    video_pressure: Option<u32>,
    touch_update: Option<PendingTouchUpdate>,
    mouse_wheel_2d: Option<PendingMouseWheel2D>,
    touch_active: bool,
    touch_scale_end_pending: bool,
    touch_pan_end_enqueued: bool,
    pending_touch_scale_end_markers: usize,
    pending_touch_pan_ends: usize,
    max_reliable_depth: usize,
    coalesced_mouse_moves: u64,
    coalesced_display_switches: u64,
    discarded_pointer_updates: u64,
    coalesced_refreshes: u64,
    coalesced_video_pressure: u64,
    coalesced_touch_scales: u64,
    coalesced_touch_pan_updates: u64,
    coalesced_mouse_wheel_2d: u64,
    batch_limit_hits: u64,
}

impl Default for ControlInboxState {
    fn default() -> Self {
        Self {
            next_sequence: 1,
            reliable: VecDeque::new(),
            display_switch: None,
            mouse_move: None,
            refresh_pending: false,
            video_pressure: None,
            touch_update: None,
            mouse_wheel_2d: None,
            touch_active: false,
            touch_scale_end_pending: false,
            touch_pan_end_enqueued: false,
            pending_touch_scale_end_markers: 0,
            pending_touch_pan_ends: 0,
            max_reliable_depth: 0,
            coalesced_mouse_moves: 0,
            coalesced_display_switches: 0,
            discarded_pointer_updates: 0,
            coalesced_refreshes: 0,
            coalesced_video_pressure: 0,
            coalesced_touch_scales: 0,
            coalesced_touch_pan_updates: 0,
            coalesced_mouse_wheel_2d: 0,
            batch_limit_hits: 0,
        }
    }
}

impl Default for ControlInbox {
    fn default() -> Self {
        Self {
            shutdown: AtomicBool::new(false),
            permission_known: AtomicU32::new(0),
            permission_enabled: AtomicU32::new(0),
            state: Mutex::new(ControlInboxState::default()),
        }
    }
}

enum OrderedPending {
    Reliable,
    MouseMove,
    TouchUpdate,
    MouseWheel2D,
    DisplaySwitch,
}

impl ControlInbox {
    /// Returns false when a touch update is sent outside an active touch
    /// stream. This keeps callers from claiming gesture ownership after a
    /// session has already rejected the start event.
    pub(crate) fn enqueue(&self, message: ControlMsg) -> bool {
        if matches!(&message, ControlMsg::Shutdown) {
            self.request_shutdown();
            return true;
        }

        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        if let Some(permission) = required_permission(&message) {
            let known = self.permission_known.load(Ordering::Acquire);
            let enabled = self.permission_enabled.load(Ordering::Acquire);
            if known & permission != 0 && enabled & permission == 0 {
                return false;
            }
        }
        let sequence = Self::next_sequence(&mut state);

        match message {
            ControlMsg::MouseWheel2D { x, y } => {
                if x == 0 && y == 0 {
                    return false;
                }
                Self::merge_mouse_wheel_2d(&mut state, sequence, x, y);
                true
            }
            ControlMsg::MouseMove { .. } => {
                if state
                    .mouse_move
                    .replace(SequencedControl { sequence, message })
                    .is_some()
                {
                    state.coalesced_mouse_moves += 1;
                }
                true
            }
            ControlMsg::DisplaySwitch { .. } => {
                // Display selection is a coordinate-space barrier. Keep the
                // release messages already queued by ArkTS, but discard old
                // coalesced movement/deltas so they cannot cross into the new
                // monitor. The switch itself is a latest-value-wins ordered
                // slot and is emitted as one official single-canvas sequence.
                Self::discard_stale_pointer_updates(&mut state);
                if state
                    .display_switch
                    .replace(SequencedControl { sequence, message })
                    .is_some()
                {
                    state.coalesced_display_switches += 1;
                }
                true
            }
            ControlMsg::RefreshVideo => {
                if state.refresh_pending {
                    state.coalesced_refreshes += 1;
                }
                state.refresh_pending = true;
                true
            }
            ControlMsg::VideoPressure { level } => {
                if state.video_pressure.replace(level).is_some() {
                    state.coalesced_video_pressure += 1;
                }
                true
            }
            ControlMsg::TouchPanStart { x, y } => {
                // A new start begins a fresh remote touch stream. Any update
                // retained from an abandoned stream must not cross this
                // boundary.
                state.touch_update = None;
                state.touch_active = true;
                state.touch_scale_end_pending = false;
                state.touch_pan_end_enqueued = false;
                Self::enqueue_reliable(&mut state, sequence, ControlMsg::TouchPanStart { x, y });
                true
            }
            ControlMsg::TouchScale { scale } if scale > 0 => {
                if !state.touch_active || state.touch_scale_end_pending {
                    return false;
                }
                Self::merge_touch_scale(&mut state, sequence, scale);
                true
            }
            ControlMsg::TouchScale { scale: 0 } => {
                if !state.touch_active || state.touch_scale_end_pending {
                    return false;
                }
                Self::flush_coalesced_pointer_updates_before_reliable(&mut state);
                // The accumulated update was flushed above, so this reliable
                // end marker is necessarily sent after the latest deltas.
                state.touch_scale_end_pending = true;
                state.touch_active = false;
                state.pending_touch_scale_end_markers += 1;
                Self::enqueue_reliable(&mut state, sequence, ControlMsg::TouchScale { scale: 0 });
                true
            }
            ControlMsg::TouchPanUpdate { x, y } => {
                if !state.touch_active || state.touch_scale_end_pending {
                    return false;
                }
                Self::merge_touch_pan(&mut state, sequence, x, y);
                true
            }
            ControlMsg::TouchPanEnd { x, y } => {
                if state.touch_pan_end_enqueued
                    || (!state.touch_active && !state.touch_scale_end_pending)
                {
                    return false;
                }
                Self::flush_coalesced_pointer_updates_before_reliable(&mut state);
                state.touch_active = false;
                state.touch_scale_end_pending = true;
                state.touch_pan_end_enqueued = true;
                state.pending_touch_pan_ends += 1;
                // The accumulated update was flushed above before this
                // reliable barrier was appended.
                Self::enqueue_reliable(&mut state, sequence, ControlMsg::TouchPanEnd { x, y });
                true
            }
            reliable => {
                Self::flush_coalesced_pointer_updates_before_reliable(&mut state);
                Self::enqueue_reliable(&mut state, sequence, reliable);
                true
            }
        }
    }

    pub(crate) fn take_batch(&self, limit: usize) -> Vec<ControlMsg> {
        if limit == 0 {
            return Vec::new();
        }

        let Ok(mut state) = self.state.lock() else {
            return Vec::new();
        };
        let mut batch = Vec::with_capacity(limit);

        // Reliable controls, the unified touch slots, and the coalesced mouse
        // coordinate share one ordering domain. The mouse coordinate remains
        // latest-value-wins, but its sequence prevents a click from overtaking
        // the movement that positions the remote pointer over the target.
        while batch.len() < limit {
            let Some(next) = Self::next_ordered_pending(&state) else {
                break;
            };
            match next {
                OrderedPending::Reliable => {
                    let Some(queued) = state.reliable.pop_front() else {
                        break;
                    };
                    Self::on_reliable_sent(&mut state, &queued.message);
                    batch.push(queued.message);
                }
                OrderedPending::MouseMove => {
                    let Some(queued) = state.mouse_move.take() else {
                        break;
                    };
                    batch.push(queued.message);
                }
                OrderedPending::TouchUpdate => {
                    Self::take_touch_update(&mut state, &mut batch, limit);
                }
                OrderedPending::MouseWheel2D => {
                    Self::take_mouse_wheel_2d(&mut state, &mut batch);
                }
                OrderedPending::DisplaySwitch => {
                    let Some(queued) = state.display_switch.take() else {
                        break;
                    };
                    batch.push(queued.message);
                }
            }
        }

        if batch.len() < limit && state.refresh_pending {
            state.refresh_pending = false;
            batch.push(ControlMsg::RefreshVideo);
        }
        if batch.len() < limit {
            if let Some(level) = state.video_pressure.take() {
                batch.push(ControlMsg::VideoPressure { level });
            }
        }

        if batch.len() == limit && Self::has_pending(&state) {
            state.batch_limit_hits += 1;
        }
        batch
    }

    pub(crate) fn request_shutdown(&self) {
        self.shutdown.store(true, Ordering::Release);
    }

    pub(crate) fn shutdown_requested(&self) -> bool {
        self.shutdown.load(Ordering::Acquire)
    }

    /// Apply a permission update sent by the remote peer. Unknown permissions
    /// remain optimistic for compatibility with older peers that never emit
    /// `PermissionInfo`; an explicit denial takes effect immediately and also
    /// removes already queued controls protected by that permission.
    pub(crate) fn update_permission(&self, permission: u32, enabled: bool) {
        if permission == 0 {
            return;
        }
        if enabled {
            self.permission_enabled.fetch_or(permission, Ordering::Release);
        } else {
            self.permission_enabled.fetch_and(!permission, Ordering::Release);
        }
        self.permission_known.fetch_or(permission, Ordering::Release);

        if enabled {
            return;
        }
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        Self::discard_permission_controls(&mut state, permission);
    }

    pub(crate) fn permission_snapshot(&self) -> PermissionSnapshot {
        PermissionSnapshot {
            known_mask: self.permission_known.load(Ordering::Acquire),
            enabled_mask: self.permission_enabled.load(Ordering::Acquire),
        }
    }

    pub(crate) fn snapshot(&self) -> ControlInboxSnapshot {
        let Ok(state) = self.state.lock() else {
            return ControlInboxSnapshot::default();
        };
        ControlInboxSnapshot {
            reliable_depth: state.reliable.len(),
            max_reliable_depth: state.max_reliable_depth,
            coalesced_mouse_moves: state.coalesced_mouse_moves,
            coalesced_display_switches: state.coalesced_display_switches,
            discarded_pointer_updates: state.discarded_pointer_updates,
            coalesced_refreshes: state.coalesced_refreshes,
            coalesced_video_pressure: state.coalesced_video_pressure,
            coalesced_touch_scales: state.coalesced_touch_scales,
            coalesced_touch_pan_updates: state.coalesced_touch_pan_updates,
            coalesced_mouse_wheel_2d: state.coalesced_mouse_wheel_2d,
            touch_active: state.touch_active,
            touch_update_pending: state.touch_update.is_some(),
            mouse_wheel_2d_pending: state.mouse_wheel_2d.is_some(),
            touch_barrier_wait: state.pending_touch_scale_end_markers > 0
                || state.pending_touch_pan_ends > 0,
            batch_limit_hits: state.batch_limit_hits,
        }
    }

    fn next_sequence(state: &mut ControlInboxState) -> u64 {
        let sequence = state.next_sequence;
        state.next_sequence = state.next_sequence.saturating_add(1);
        sequence
    }

    fn enqueue_reliable(state: &mut ControlInboxState, sequence: u64, message: ControlMsg) {
        state
            .reliable
            .push_back(SequencedControl { sequence, message });
        state.max_reliable_depth = state.max_reliable_depth.max(state.reliable.len());
    }

    fn flush_coalesced_pointer_updates_before_reliable(state: &mut ControlInboxState) {
        let touch = state.touch_update.take();
        let wheel = state.mouse_wheel_2d.take();
        match (touch, wheel) {
            (Some(touch), Some(wheel)) if touch.sequence <= wheel.sequence => {
                Self::enqueue_touch_update(state, touch);
                Self::enqueue_mouse_wheel_2d(state, wheel);
            }
            (Some(touch), Some(wheel)) => {
                Self::enqueue_mouse_wheel_2d(state, wheel);
                Self::enqueue_touch_update(state, touch);
            }
            (Some(touch), None) => Self::enqueue_touch_update(state, touch),
            (None, Some(wheel)) => Self::enqueue_mouse_wheel_2d(state, wheel),
            (None, None) => {}
        }
    }

    fn enqueue_touch_update(state: &mut ControlInboxState, mut pending: PendingTouchUpdate) {
        let sequence = pending.sequence;
        if let Some(scale) = pending.scale.take() {
            Self::enqueue_reliable(state, sequence, ControlMsg::TouchScale { scale });
        }
        if let Some((x, y)) = pending.pan.take() {
            Self::enqueue_reliable(state, sequence, ControlMsg::TouchPanUpdate { x, y });
        }
    }

    fn enqueue_mouse_wheel_2d(state: &mut ControlInboxState, pending: PendingMouseWheel2D) {
        Self::enqueue_reliable(
            state,
            pending.sequence,
            ControlMsg::MouseWheel2D {
                x: pending.x,
                y: pending.y,
            },
        );
    }

    fn discard_stale_pointer_updates(state: &mut ControlInboxState) {
        if state.mouse_move.take().is_some() {
            state.discarded_pointer_updates += 1;
        }
        if let Some(pending) = state.touch_update.take() {
            state.discarded_pointer_updates += usize::from(pending.scale.is_some()) as u64;
            state.discarded_pointer_updates += usize::from(pending.pan.is_some()) as u64;
        }
        if state.mouse_wheel_2d.take().is_some() {
            state.discarded_pointer_updates += 1;
        }
        let previous_depth = state.reliable.len();
        state.reliable.retain(|queued| {
            !matches!(
                &queued.message,
                ControlMsg::TouchScale { scale } if *scale > 0
            ) && !matches!(&queued.message, ControlMsg::TouchPanUpdate { .. })
                && !matches!(&queued.message, ControlMsg::MouseWheel2D { .. })
        });
        state.discarded_pointer_updates +=
            previous_depth.saturating_sub(state.reliable.len()) as u64;
    }

    fn discard_permission_controls(state: &mut ControlInboxState, permission: u32) {
        state.reliable.retain(|queued| {
            required_permission(&queued.message) != Some(permission)
        });
        if state
            .mouse_move
            .as_ref()
            .is_some_and(|queued| required_permission(&queued.message) == Some(permission))
        {
            state.mouse_move = None;
        }
        if permission == PERMISSION_KEYBOARD {
            state.touch_update = None;
            state.mouse_wheel_2d = None;
            state.touch_active = false;
            state.touch_scale_end_pending = false;
            state.touch_pan_end_enqueued = false;
            state.pending_touch_scale_end_markers = 0;
            state.pending_touch_pan_ends = 0;
        }
    }

    fn merge_touch_scale(state: &mut ControlInboxState, sequence: u64, scale: i32) {
        let Some(pending) = state.touch_update.as_mut() else {
            state.touch_update = Some(PendingTouchUpdate {
                sequence,
                scale: Some(scale),
                pan: None,
            });
            return;
        };
        if let Some(previous) = pending.scale {
            pending.scale = Some(combine_scale_delta(previous, scale));
            state.coalesced_touch_scales += 1;
        } else {
            pending.scale = Some(scale);
        }
        pending.sequence = sequence;
    }

    fn merge_touch_pan(state: &mut ControlInboxState, sequence: u64, x: i32, y: i32) {
        let Some(pending) = state.touch_update.as_mut() else {
            state.touch_update = Some(PendingTouchUpdate {
                sequence,
                scale: None,
                pan: Some((x, y)),
            });
            return;
        };
        if let Some((previous_x, previous_y)) = pending.pan {
            pending.pan = Some((previous_x.saturating_add(x), previous_y.saturating_add(y)));
            state.coalesced_touch_pan_updates += 1;
        } else {
            pending.pan = Some((x, y));
        }
        pending.sequence = sequence;
    }

    fn merge_mouse_wheel_2d(state: &mut ControlInboxState, sequence: u64, x: i32, y: i32) {
        let Some(pending) = state.mouse_wheel_2d.as_mut() else {
            state.mouse_wheel_2d = Some(PendingMouseWheel2D { sequence, x, y });
            return;
        };
        pending.x = pending.x.saturating_add(x);
        pending.y = pending.y.saturating_add(y);
        pending.sequence = sequence;
        state.coalesced_mouse_wheel_2d += 1;
    }

    fn next_ordered_pending(state: &ControlInboxState) -> Option<OrderedPending> {
        let mut selected: Option<(u64, OrderedPending)> = None;
        if let Some(reliable) = state.reliable.front() {
            selected = Some((reliable.sequence, OrderedPending::Reliable));
        }
        if let Some(mouse_move) = state.mouse_move.as_ref() {
            if selected
                .as_ref()
                .map_or(true, |(sequence, _)| mouse_move.sequence < *sequence)
            {
                selected = Some((mouse_move.sequence, OrderedPending::MouseMove));
            }
        }
        if let Some(touch) = state.touch_update.as_ref() {
            if selected
                .as_ref()
                .map_or(true, |(sequence, _)| touch.sequence < *sequence)
            {
                selected = Some((touch.sequence, OrderedPending::TouchUpdate));
            }
        }
        if let Some(wheel) = state.mouse_wheel_2d.as_ref() {
            if selected
                .as_ref()
                .map_or(true, |(sequence, _)| wheel.sequence < *sequence)
            {
                selected = Some((wheel.sequence, OrderedPending::MouseWheel2D));
            }
        }
        if let Some(display_switch) = state.display_switch.as_ref() {
            if selected
                .as_ref()
                .map_or(true, |(sequence, _)| display_switch.sequence < *sequence)
            {
                selected = Some((display_switch.sequence, OrderedPending::DisplaySwitch));
            }
        }
        selected.map(|(_, pending)| pending)
    }

    fn take_touch_update(state: &mut ControlInboxState, batch: &mut Vec<ControlMsg>, limit: usize) {
        let Some(mut pending) = state.touch_update.take() else {
            return;
        };
        if let Some(scale) = pending.scale.take() {
            batch.push(ControlMsg::TouchScale { scale });
        }
        if batch.len() < limit {
            if let Some((x, y)) = pending.pan.take() {
                batch.push(ControlMsg::TouchPanUpdate { x, y });
            }
        }
        if !pending.is_empty() {
            state.touch_update = Some(pending);
        }
    }

    fn take_mouse_wheel_2d(state: &mut ControlInboxState, batch: &mut Vec<ControlMsg>) {
        let Some(pending) = state.mouse_wheel_2d.take() else {
            return;
        };
        batch.push(ControlMsg::MouseWheel2D {
            x: pending.x,
            y: pending.y,
        });
    }

    fn on_reliable_sent(state: &mut ControlInboxState, message: &ControlMsg) {
        match message {
            ControlMsg::TouchScale { scale: 0 } => {
                state.pending_touch_scale_end_markers =
                    state.pending_touch_scale_end_markers.saturating_sub(1);
            }
            ControlMsg::TouchPanEnd { .. } => {
                state.pending_touch_pan_ends = state.pending_touch_pan_ends.saturating_sub(1);
            }
            _ => {}
        }
    }

    fn has_pending(state: &ControlInboxState) -> bool {
        !state.reliable.is_empty()
            || state.mouse_move.is_some()
            || state.mouse_wheel_2d.is_some()
            || state.display_switch.is_some()
            || state.refresh_pending
            || state.video_pressure.is_some()
            || state.touch_update.is_some()
    }
}

fn required_permission(message: &ControlMsg) -> Option<u32> {
    match message {
        ControlMsg::KeyEvent { .. }
        | ControlMsg::MouseEvent { .. }
        | ControlMsg::MouseMove { .. }
        | ControlMsg::MouseWheel { .. }
        | ControlMsg::MouseWheel2D { .. }
        | ControlMsg::Text { .. }
        | ControlMsg::TouchScale { .. }
        | ControlMsg::TouchPanStart { .. }
        | ControlMsg::TouchPanUpdate { .. }
        | ControlMsg::TouchPanEnd { .. } => Some(PERMISSION_KEYBOARD),
        ControlMsg::Clipboard { .. } => Some(PERMISSION_CLIPBOARD),
        ControlMsg::SendFile { .. } => Some(PERMISSION_FILE),
        _ => None,
    }
}

fn combine_scale_delta(previous: i32, next: i32) -> i32 {
    let combined = (i128::from(previous) * i128::from(next)) / TOUCH_SCALE_BASE;
    combined.clamp(i128::from(i32::MIN), i128::from(i32::MAX)) as i32
}

#[test]
fn mouse_moves_coalesce_to_the_latest_coordinate() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseMove { x: 1, y: 2 });
    inbox.enqueue(ControlMsg::MouseMove { x: 8, y: 9 });

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [ControlMsg::MouseMove { x: 8, y: 9 }]
    ));
    assert_eq!(inbox.snapshot().coalesced_mouse_moves, 1);
}

#[test]
fn mouse_move_precedes_following_button_event() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseMove { x: 120, y: 340 });
    inbox.enqueue(ControlMsg::MouseEvent {
        x: 120,
        y: 340,
        button: 0,
        pressed: true,
    });

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [
            ControlMsg::MouseMove { x: 120, y: 340 },
            ControlMsg::MouseEvent {
                x: 120,
                y: 340,
                button: 0,
                pressed: true,
            }
        ]
    ));
}

#[test]
fn button_event_precedes_following_mouse_move() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseEvent {
        x: 120,
        y: 340,
        button: 0,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::MouseMove { x: 900, y: 700 });

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [
            ControlMsg::MouseEvent {
                x: 120,
                y: 340,
                button: 0,
                pressed: true,
            },
            ControlMsg::MouseMove { x: 900, y: 700 },
        ]
    ));
}

#[test]
fn physical_click_keeps_latest_drag_move_between_down_and_up() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseEvent {
        x: 120,
        y: 340,
        button: 0,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::MouseMove { x: 121, y: 341 });
    inbox.enqueue(ControlMsg::MouseMove { x: 124, y: 345 });
    inbox.enqueue(ControlMsg::MouseEvent {
        x: 124,
        y: 345,
        button: 0,
        pressed: false,
    });

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [
            ControlMsg::MouseEvent { pressed: true, .. },
            ControlMsg::MouseMove { x: 124, y: 345 },
            ControlMsg::MouseEvent { pressed: false, .. },
        ]
    ));
}

#[test]
fn physical_touchpad_wheels_coalesce_both_axes_without_losing_sign() {
    let inbox = ControlInbox::default();
    assert!(inbox.enqueue(ControlMsg::MouseWheel2D { x: 2, y: -3 }));
    assert!(inbox.enqueue(ControlMsg::MouseWheel2D { x: -5, y: 7 }));

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [ControlMsg::MouseWheel2D { x: -3, y: 4 }]
    ));
    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.coalesced_mouse_wheel_2d, 1);
    assert!(!snapshot.mouse_wheel_2d_pending);
}

#[test]
fn physical_touchpad_wheel_flushes_before_reliable_keyboard_input() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseWheel2D { x: 4, y: 5 });
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 2072,
        pressed: true,
    });

    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [
            ControlMsg::MouseWheel2D { x: 4, y: 5 },
            ControlMsg::KeyEvent { pressed: true, .. }
        ]
    ));
}

#[test]
fn display_switch_drops_old_pointer_updates_and_keeps_release_order() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::MouseMove { x: 40, y: 50 });
    inbox.enqueue(ControlMsg::TouchPanStart { x: 40, y: 50 });
    inbox.enqueue(ControlMsg::TouchPanUpdate { x: 5, y: 6 });
    inbox.enqueue(ControlMsg::TouchPanEnd { x: 45, y: 56 });
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 2072,
        pressed: false,
    });
    inbox.enqueue(ControlMsg::DisplaySwitch {
        display: 1,
        generation: 1,
    });
    inbox.enqueue(ControlMsg::DisplaySwitch {
        display: 2,
        generation: 2,
    });

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(
        batch.as_slice(),
        [
            ControlMsg::TouchPanStart { .. },
            ControlMsg::TouchPanEnd { .. },
            ControlMsg::KeyEvent { pressed: false, .. },
            ControlMsg::DisplaySwitch {
                display: 2,
                generation: 2
            },
        ]
    ));
    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.coalesced_display_switches, 1);
    assert_eq!(snapshot.discarded_pointer_updates, 2);
}

#[test]
fn reliable_ime_messages_and_mouse_keep_enqueue_order_when_coalesced() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::Text {
        text: "中文😀".into(),
    });
    inbox.enqueue(ControlMsg::MouseMove { x: 1, y: 2 });
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 2014,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::Text { text: "X".into() });

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(batch[0], ControlMsg::Text { .. }));
    assert!(matches!(batch[1], ControlMsg::MouseMove { .. }));
    assert!(matches!(batch[2], ControlMsg::KeyEvent { .. }));
    assert!(matches!(batch[3], ControlMsg::Text { .. }));
}

#[test]
fn batch_limit_leaves_remaining_reliable_work_for_the_next_receive_turn() {
    let inbox = ControlInbox::default();
    for scancode in 0..9 {
        inbox.enqueue(ControlMsg::KeyEvent {
            scancode,
            pressed: true,
        });
    }

    assert_eq!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).len(),
        CONTROL_BATCH_LIMIT
    );
    assert_eq!(inbox.snapshot().reliable_depth, 1);
    assert_eq!(inbox.snapshot().batch_limit_hits, 1);
}

#[test]
fn shutdown_is_visible_without_waiting_for_a_queued_message() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 1,
        pressed: true,
    });

    inbox.request_shutdown();

    assert!(inbox.shutdown_requested());
    assert_eq!(inbox.snapshot().reliable_depth, 1);
}

#[test]
fn explicit_view_only_permission_drops_pending_input_and_rejects_new_input() {
    let inbox = ControlInbox::default();
    assert!(inbox.enqueue(ControlMsg::MouseMove { x: 10, y: 20 }));
    assert!(inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 30,
        pressed: true,
    }));
    assert!(inbox.enqueue(ControlMsg::RefreshVideo));

    inbox.update_permission(PERMISSION_KEYBOARD, false);

    assert!(!inbox.enqueue(ControlMsg::MouseMove { x: 30, y: 40 }));
    assert!(!inbox.enqueue(ControlMsg::Text { text: "blocked".into() }));
    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [ControlMsg::RefreshVideo]
    ));
    assert_eq!(
        inbox.permission_snapshot(),
        PermissionSnapshot {
            known_mask: PERMISSION_KEYBOARD,
            enabled_mask: 0,
        }
    );
}

#[test]
fn old_peers_remain_optimistic_until_a_permission_is_explicitly_denied() {
    let inbox = ControlInbox::default();
    assert!(inbox.enqueue(ControlMsg::Clipboard {
        content: b"first".to_vec(),
    }));
    inbox.update_permission(PERMISSION_CLIPBOARD, false);
    assert!(!inbox.enqueue(ControlMsg::Clipboard {
        content: b"second".to_vec(),
    }));
    inbox.update_permission(PERMISSION_CLIPBOARD, true);
    assert!(inbox.enqueue(ControlMsg::Clipboard {
        content: b"third".to_vec(),
    }));
    assert!(matches!(
        inbox.take_batch(CONTROL_BATCH_LIMIT).as_slice(),
        [ControlMsg::Clipboard { content }] if content == b"third"
    ));
}

#[test]
fn duplicate_refresh_and_pressure_are_coalesced() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::RefreshVideo);
    inbox.enqueue(ControlMsg::RefreshVideo);
    inbox.enqueue(ControlMsg::VideoPressure { level: 1 });
    inbox.enqueue(ControlMsg::VideoPressure { level: 3 });

    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.coalesced_refreshes, 1);
    assert_eq!(snapshot.coalesced_video_pressure, 1);
}

#[test]
fn touch_deltas_are_combined_without_losing_protocol_semantics() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::TouchPanStart { x: 100, y: 200 });

    let mut expected_scale = 1000;
    let mut expected_x: i32 = 0;
    let mut expected_y: i32 = 0;
    for index in 0..100 {
        let scale = 1000 + (index % 5);
        expected_scale = combine_scale_delta(expected_scale, scale);
        expected_x = expected_x.saturating_add(index);
        expected_y = expected_y.saturating_sub(index);
        inbox.enqueue(ControlMsg::TouchScale { scale });
        inbox.enqueue(ControlMsg::TouchPanUpdate {
            x: index,
            y: -index,
        });
    }

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(
        batch[0],
        ControlMsg::TouchPanStart { x: 100, y: 200 }
    ));
    assert!(matches!(
        batch[1],
        ControlMsg::TouchScale { scale } if scale == expected_scale
    ));
    assert!(matches!(
        batch[2],
        ControlMsg::TouchPanUpdate { x, y } if x == expected_x && y == expected_y
    ));
    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.coalesced_touch_scales, 99);
    assert_eq!(snapshot.coalesced_touch_pan_updates, 99);
    assert!(!snapshot.touch_update_pending);
}

#[test]
fn touch_end_markers_are_barriers_and_repeated_end_is_ignored() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::TouchPanStart { x: 0, y: 0 });
    inbox.enqueue(ControlMsg::TouchScale { scale: 1100 });
    inbox.enqueue(ControlMsg::TouchPanUpdate { x: 3, y: 4 });
    assert!(inbox.enqueue(ControlMsg::TouchScale { scale: 0 }));
    assert!(inbox.enqueue(ControlMsg::TouchPanEnd { x: 3, y: 4 }));
    assert!(!inbox.enqueue(ControlMsg::TouchScale { scale: 0 }));
    assert!(!inbox.enqueue(ControlMsg::TouchPanEnd { x: 3, y: 4 }));

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(
        batch.as_slice(),
        [
            ControlMsg::TouchPanStart { .. },
            ControlMsg::TouchScale { scale: 1100 },
            ControlMsg::TouchPanUpdate { x: 3, y: 4 },
            ControlMsg::TouchScale { scale: 0 },
            ControlMsg::TouchPanEnd { x: 3, y: 4 },
        ]
    ));
    let snapshot = inbox.snapshot();
    assert!(!snapshot.touch_active);
    assert!(!snapshot.touch_barrier_wait);
}

#[test]
fn touch_start_clears_an_abandoned_update_slot() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::TouchPanStart { x: 0, y: 0 });
    inbox.enqueue(ControlMsg::TouchScale { scale: 1200 });
    inbox.enqueue(ControlMsg::TouchPanUpdate { x: 20, y: 30 });
    inbox.enqueue(ControlMsg::TouchPanStart { x: 5, y: 6 });

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(
        batch.as_slice(),
        [
            ControlMsg::TouchPanStart { x: 0, y: 0 },
            ControlMsg::TouchPanStart { x: 5, y: 6 },
        ]
    ));
}

#[test]
fn touch_updates_do_not_create_reliable_backlog_behind_input_buttons() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::TouchPanStart { x: 0, y: 0 });
    for index in 0..100 {
        inbox.enqueue(ControlMsg::TouchScale {
            scale: 1000 + (index % 5),
        });
        inbox.enqueue(ControlMsg::TouchPanUpdate {
            x: index,
            y: -index,
        });
    }
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 2014,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::MouseEvent {
        x: 10,
        y: 20,
        button: 0,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::TouchScale { scale: 0 });
    inbox.enqueue(ControlMsg::TouchPanEnd { x: 99, y: -99 });

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert_eq!(batch.len(), 7);
    assert!(matches!(batch[0], ControlMsg::TouchPanStart { .. }));
    assert!(matches!(batch[1], ControlMsg::TouchScale { scale } if scale > 0));
    assert!(matches!(
        batch[2],
        ControlMsg::TouchPanUpdate { x: 4950, y: -4950 }
    ));
    assert!(matches!(batch[3], ControlMsg::KeyEvent { .. }));
    assert!(matches!(batch[4], ControlMsg::MouseEvent { .. }));
    assert!(matches!(batch[5], ControlMsg::TouchScale { scale: 0 }));
    assert!(matches!(batch[6], ControlMsg::TouchPanEnd { .. }));
    let snapshot = inbox.snapshot();
    assert_eq!(snapshot.max_reliable_depth, 7);
    assert_eq!(snapshot.coalesced_touch_scales, 99);
    assert_eq!(snapshot.coalesced_touch_pan_updates, 99);
}

#[test]
fn reliable_input_flushes_touch_updates_at_the_order_boundary() {
    let inbox = ControlInbox::default();
    inbox.enqueue(ControlMsg::TouchPanStart { x: 0, y: 0 });
    inbox.enqueue(ControlMsg::TouchScale { scale: 1100 });
    inbox.enqueue(ControlMsg::TouchPanUpdate { x: 1, y: 2 });
    inbox.enqueue(ControlMsg::KeyEvent {
        scancode: 2014,
        pressed: true,
    });
    inbox.enqueue(ControlMsg::TouchScale { scale: 1200 });
    inbox.enqueue(ControlMsg::TouchPanUpdate { x: 3, y: 4 });

    let batch = inbox.take_batch(CONTROL_BATCH_LIMIT);
    assert!(matches!(
        batch.as_slice(),
        [
            ControlMsg::TouchPanStart { .. },
            ControlMsg::TouchScale { scale: 1100 },
            ControlMsg::TouchPanUpdate { x: 1, y: 2 },
            ControlMsg::KeyEvent { pressed: true, .. },
            ControlMsg::TouchScale { scale: 1200 },
            ControlMsg::TouchPanUpdate { x: 3, y: 4 },
        ]
    ));
}
