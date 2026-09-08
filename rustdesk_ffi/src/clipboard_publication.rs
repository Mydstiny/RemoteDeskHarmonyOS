//! Publication identity and a write receipt, separate from incoming clipboard state.
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

struct Receipt {
    state: AtomicU32,
    created: Instant,
    writing: AtomicBool,
}
impl Receipt {
    fn state(&self) -> u32 {
        if self.created.elapsed() >= Duration::from_secs(5) && !self.writing.load(Ordering::Acquire) {
            self.fail();
        }
        self.state.load(Ordering::Acquire)
    }
    fn fail(&self) {
        let _ = self
            .state
            .compare_exchange(1, 3, Ordering::AcqRel, Ordering::Acquire);
    }
}
/// One token is moved with the queued message. Dropping it without a write is failure.
pub(crate) struct PublicationToken(
    Arc<Receipt>,
    Option<Weak<crate::control_inbox::ControlInbox>>,
    u32,
    Option<Weak<AtomicBool>>,
);
#[derive(Clone)]
pub(crate) struct PublicationObservation(Arc<Receipt>);
impl PublicationObservation { pub fn state(&self) -> u32 { self.0.state() } }
impl PublicationToken {
    pub fn for_file_clipboard(controls: Weak<crate::control_inbox::ControlInbox>, permission_mask: u32, gate: Weak<AtomicBool>) -> (PublicationObservation, Self) {
        let receipt = Arc::new(Receipt { state: AtomicU32::new(1), created: Instant::now(), writing: AtomicBool::new(false) });
        (PublicationObservation(receipt.clone()), Self(receipt, Some(controls), permission_mask, Some(gate)))
    }
    pub fn begin_write(&self) -> bool {
        if !self.pending() { return false; }
        self.0.writing.store(true, Ordering::Release);
        self.pending()
    }
    pub fn bind_controls(&mut self, controls: Arc<crate::control_inbox::ControlInbox>) {
        self.1 = Some(Arc::downgrade(&controls));
    }
    pub fn pending(&self) -> bool {
        if self.3.as_ref().is_some_and(|gate| !gate.upgrade().is_some_and(|v| v.load(Ordering::Acquire))) { self.0.fail(); }
        if let Some(owner) = &self.1 {
            if let Some(controls) = owner.upgrade() {
                let p = controls.permission_snapshot();
                let clipboard = self.2;
                if controls.shutdown_requested()
                    || (p.known_mask & clipboard & !p.enabled_mask != 0)
                {
                    self.0.fail();
                }
            } else {
                self.0.fail();
            }
        }
        self.0.state() == 1
    }
    pub fn written(&self) {
        let _ = self
            .0
            .state
            .compare_exchange(1, 2, Ordering::AcqRel, Ordering::Acquire);
    }
}
impl Drop for PublicationToken {
    fn drop(&mut self) {
        self.0.fail();
    }
}
#[derive(Default)]
pub(crate) struct Publications {
    next: u64,
    receipts: BTreeMap<u64, Arc<Receipt>>,
}
impl Publications {
    pub fn reserve(&mut self) -> Option<(u64, PublicationToken)> {
        if self.receipts.len() >= 64 {
            let completed = self
                .receipts
                .iter()
                .find(|(_, r)| r.state() != 1)
                .map(|(id, _)| *id)?;
            self.receipts.remove(&completed);
        }
        self.next = self.next.checked_add(1)?;
        let receipt = Arc::new(Receipt {
            state: AtomicU32::new(1),
            created: Instant::now(),
            writing: AtomicBool::new(false),
        });
        self.receipts.insert(self.next, receipt.clone());
        Some((self.next, PublicationToken(receipt, None, crate::control_inbox::PERMISSION_CLIPBOARD, None)))
    }
    pub fn state(&self, id: u64, shutdown: bool) -> u32 {
        self.receipts
            .get(&id)
            .map(|r| {
                if shutdown {
                    r.fail();
                }
                r.state()
            })
            .unwrap_or(0)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_publication_requires_write_and_drop_rejects() {
        let mut p = Publications::default();
        let (a, token) = p.reserve().unwrap();
        assert_eq!(p.state(a, false), 1);
        drop(token);
        assert_eq!(p.state(a, false), 3);
        let (b, token) = p.reserve().unwrap();
        token.written();
        drop(token);
        assert_eq!(p.state(b, false), 2);
        assert_eq!(p.state(a, false), 3);
    }
    #[test]
    fn clipboard_publication_disconnect_cannot_become_written_later() {
        let mut p = Publications::default();
        let (id, token) = p.reserve().unwrap();
        assert_eq!(p.state(id, true), 3);
        token.written();
        assert_eq!(p.state(id, false), 3);
    }
    #[test]
    fn clipboard_publication_capacity_never_evicts_pending() {
        let mut p = Publications::default();
        let tokens: Vec<_> = (0..64).map(|_| p.reserve().unwrap().1).collect();
        assert!(p.reserve().is_none());
        drop(tokens);
        assert!(p.reserve().is_some());
    }
    #[test]
    fn clipboard_publication_expired_cannot_be_written() {
        let receipt = Arc::new(Receipt {
            state: AtomicU32::new(1),
            created: Instant::now() - Duration::from_secs(6),
            writing: AtomicBool::new(false),
        });
        let token = PublicationToken(receipt, None, crate::control_inbox::PERMISSION_CLIPBOARD, None);
        assert!(!token.pending());
        token.written();
        assert_eq!(token.0.state(), 3);
    }
    #[test]
    fn clipboard_publication_token_does_not_keep_its_own_inbox_alive() {
        let mut publications = Publications::default();
        let controls = Arc::new(crate::control_inbox::ControlInbox::default());
        let weak = Arc::downgrade(&controls);
        let (id, mut token) = publications.reserve().unwrap();
        token.bind_controls(controls.clone());
        assert!(controls.enqueue(crate::ControlMsg::ClipboardTracked {
            content: b"pending".to_vec(),
            receipt: token
        }));
        drop(controls);
        assert!(weak.upgrade().is_none());
        assert_eq!(publications.state(id, false), 3);
    }
}
