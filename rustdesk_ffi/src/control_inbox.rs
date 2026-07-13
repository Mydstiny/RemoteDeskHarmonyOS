use crate::ControlMsg;
use std::collections::VecDeque;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

pub(crate) const CONTROL_BATCH_LIMIT: usize = 8;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ControlInboxSnapshot {
    pub reliable_depth: usize,
    pub max_reliable_depth: usize,
    pub coalesced_mouse_moves: u64,
    pub coalesced_refreshes: u64,
    pub coalesced_video_pressure: u64,
    pub batch_limit_hits: u64,
}

pub(crate) struct ControlInbox {
    shutdown: AtomicBool,
    state: Mutex<ControlInboxState>,
}

struct ControlInboxState {
    reliable: VecDeque<ControlMsg>,
    mouse_move: Option<ControlMsg>,
    refresh_pending: bool,
    video_pressure: Option<u32>,
    max_reliable_depth: usize,
    coalesced_mouse_moves: u64,
    coalesced_refreshes: u64,
    coalesced_video_pressure: u64,
    batch_limit_hits: u64,
}

impl Default for ControlInboxState {
    fn default() -> Self {
        Self {
            reliable: VecDeque::new(),
            mouse_move: None,
            refresh_pending: false,
            video_pressure: None,
            max_reliable_depth: 0,
            coalesced_mouse_moves: 0,
            coalesced_refreshes: 0,
            coalesced_video_pressure: 0,
            batch_limit_hits: 0,
        }
    }
}

impl Default for ControlInbox {
    fn default() -> Self {
        Self {
            shutdown: AtomicBool::new(false),
            state: Mutex::new(ControlInboxState::default()),
        }
    }
}

impl ControlInbox {
    pub(crate) fn enqueue(&self, message: ControlMsg) {
        if matches!(message, ControlMsg::Shutdown) {
            self.request_shutdown();
            return;
        }

        let Ok(mut state) = self.state.lock() else {
            return;
        };

        match message {
            ControlMsg::MouseMove { .. } => {
                if state.mouse_move.replace(message).is_some() {
                    state.coalesced_mouse_moves += 1;
                }
            }
            ControlMsg::RefreshVideo => {
                if state.refresh_pending {
                    state.coalesced_refreshes += 1;
                }
                state.refresh_pending = true;
            }
            ControlMsg::VideoPressure { level } => {
                if state.video_pressure.replace(level).is_some() {
                    state.coalesced_video_pressure += 1;
                }
            }
            reliable => {
                state.reliable.push_back(reliable);
                state.max_reliable_depth = state.max_reliable_depth.max(state.reliable.len());
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

        while batch.len() < limit {
            let Some(message) = state.reliable.pop_front() else {
                break;
            };
            batch.push(message);
        }

        if batch.len() < limit {
            if let Some(message) = state.mouse_move.take() {
                batch.push(message);
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

    pub(crate) fn snapshot(&self) -> ControlInboxSnapshot {
        let Ok(state) = self.state.lock() else {
            return ControlInboxSnapshot::default();
        };
        ControlInboxSnapshot {
            reliable_depth: state.reliable.len(),
            max_reliable_depth: state.max_reliable_depth,
            coalesced_mouse_moves: state.coalesced_mouse_moves,
            coalesced_refreshes: state.coalesced_refreshes,
            coalesced_video_pressure: state.coalesced_video_pressure,
            batch_limit_hits: state.batch_limit_hits,
        }
    }

    fn has_pending(state: &ControlInboxState) -> bool {
        !state.reliable.is_empty()
            || state.mouse_move.is_some()
            || state.refresh_pending
            || state.video_pressure.is_some()
    }
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
fn reliable_ime_messages_remain_fifo_when_mouse_is_coalesced() {
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
    assert!(matches!(batch[1], ControlMsg::KeyEvent { .. }));
    assert!(matches!(batch[2], ControlMsg::Text { .. }));
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

    assert_eq!(inbox.take_batch(CONTROL_BATCH_LIMIT).len(), CONTROL_BATCH_LIMIT);
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
