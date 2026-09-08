//! Explicit-phone transport only. No changes to desktop mouse/key mappings.
//! RustDesk 1.4.9 input_model.dart and Android InputService.kt contracts.
use crate::protocol::message_proto::{KeyEvent, KeyEvent_oneof_union, KeyboardMode,
    Message, Message_oneof_union, MouseEvent};

// bit 1 Android; bit 2 version known; bit 3 Back button introduced in 1.3.8.
pub(crate) fn capabilities(platform: &str, version: &str) -> u32 {
    if !platform.trim().eq_ignore_ascii_case("android") { return 0; }
    let parts: Option<Vec<u32>> = version.trim().split('.').map(|p| p.parse().ok()).collect();
    match parts {
        Some(p) if p.len() == 3 => 2 | 4 | if p.as_slice() >= [1, 3, 8].as_slice() { 8 } else { 0 },
        _ => 2,
    }
}

// 0 Back; 1 Home; 2/3 recent-apps down/up; 4/5 volume up down/up;
// 6/7 volume down down/up; 8/9 power down/up. Unknown actions fail closed.
pub(crate) fn allows(capabilities: u32, action: i32) -> bool {
    capabilities & 2 != 0 && (0..=9).contains(&action) &&
        (action != 0 || capabilities & 4 != 0)
}

pub(crate) fn messages(action: i32, modern_back: bool) -> Vec<Message> {
    let mouse = |mask| {
        let mut event = MouseEvent::new();
        event.set_mask(mask);
        let mut msg = Message::new();
        msg.union = Some(Message_oneof_union::mouse_event(event));
        msg
    };
    match action {
        0 => { let button = if modern_back { 8 } else { 2 }; vec![mouse((button << 3) | 1), mouse((button << 3) | 2)] },
        1 => vec![mouse(33), mouse(34)],
        2 => vec![mouse(33)],
        3 => vec![mouse(34)],
        4..=9 => {
            // Official controller maps HID to Android platform keycodes before Map serialization.
            let code = match action { 4 | 5 => 24, 6 | 7 => 25, _ => 26 };
            let mut event = KeyEvent::new();
            event.set_mode(KeyboardMode::Map);
            event.set_down(action % 2 == 0);
            event.union = Some(KeyEvent_oneof_union::chr(code));
            let mut msg = Message::new();
            msg.union = Some(Message_oneof_union::key_event(event));
            vec![msg]
        },
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn android_phone_capabilities_fail_closed() {
        for platform in ["", "unknown", "Windows", "macOS", "Linux"] {
            for action in -1..=10 { assert!(!allows(capabilities(platform, "1.4.9"), action)); }
        }
        assert_eq!(capabilities("Android", "1.3.7"), 6);
        assert_eq!(capabilities("Android", "1.3.8"), 14);
        assert_eq!(capabilities("Android", "2.0.0"), 14);
        for version in ["", "1.4", "1.4.9-dev", "bad"] {
            assert!(!allows(capabilities("Android", version), 0));
        }
        assert!(!allows(14, -1)); assert!(!allows(14, 10));
    }
    #[test]
    fn android_phone_wire_contract() {
        let masks = |action, modern| messages(action, modern).into_iter().map(|m| {
            if let Some(Message_oneof_union::mouse_event(e)) = m.union { e.mask } else { panic!() }
        }).collect::<Vec<_>>();
        assert_eq!(masks(0, true), [65, 66]);
        assert_eq!(masks(0, false), [17, 18]);
        assert_eq!(masks(1, true), [33, 34]);
        assert_eq!(masks(2, true), [33]); assert_eq!(masks(3, true), [34]);
        for (action, code) in [(4,24),(5,24),(6,25),(7,25),(8,26),(9,26)] {
            let msg = messages(action, true).remove(0);
            if let Some(Message_oneof_union::key_event(e)) = msg.union {
                assert_eq!(e.mode, KeyboardMode::Map);
                assert_eq!(e.down, action % 2 == 0); assert_eq!(e.get_chr(), code);
            } else { panic!() }
        }
        assert!(messages(10, true).is_empty());
    }
}
