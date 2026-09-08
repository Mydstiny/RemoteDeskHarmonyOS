//! A challenge belongs to one dedicated file job, never the desktop's 2FA mailbox.
use std::io;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Mutex,
};
use std::time::{Duration, Instant};
static NEXT_CHALLENGE: AtomicU64 = AtomicU64::new(1);
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FileAuthSnapshot {
    pub transfer_id: u64,
    pub challenge_id: u64,
    pub kind: u32,
    pub state: u32,
    pub expires_in_ms: u64,
    pub attempts_remaining: u32,
    pub diagnostic_code: u32,
}
pub(crate) struct Secret(Vec<u8>);
impl Secret {
    pub fn new(value: &str) -> Self {
        Self(value.as_bytes().to_vec())
    }
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).unwrap_or("")
    }
}
impl Drop for Secret {
    fn drop(&mut self) {
        for byte in &mut self.0 {
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
        std::sync::atomic::compiler_fence(Ordering::SeqCst);
    }
}
pub(crate) struct FileAuthResponse {
    pub kind: u32,
    pub secret: Secret,
}
struct State {
    snapshot: FileAuthSnapshot,
    deadline: Option<Instant>,
    pending: Option<FileAuthResponse>,
    submissions: u32,
    closed: bool,
}
pub(crate) struct FileAuthExchange {
    state: Mutex<State>,
}
impl FileAuthExchange {
    pub fn new(id: u64) -> Self {
        Self {
            state: Mutex::new(State {
                snapshot: FileAuthSnapshot {
                    transfer_id: id,
                    ..Default::default()
                },
                deadline: None,
                pending: None,
                submissions: 0,
                closed: false,
            }),
        }
    }
    pub fn begin(&self) {
        if let Ok(mut s) = self.state.lock() {
            if s.deadline.is_none() {
                s.deadline = Some(Instant::now() + Duration::from_secs(90));
            }
        }
    }
    fn expire(s: &mut State) {
        if !s.closed && s.deadline.is_some_and(|v| Instant::now() >= v) {
            s.pending = None;
            s.closed = true;
            s.snapshot.state = 5;
            s.snapshot.diagnostic_code = 2;
        }
    }
    pub fn challenge(&self, kind: u32) -> io::Result<()> {
        let mut s = self
            .state
            .lock()
            .map_err(|_| io::Error::other("auth lock"))?;
        Self::expire(&mut s);
        if s.closed || (s.submissions >= 3 && kind != 4) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "file authentication unavailable",
            ));
        }
        s.pending = None;
        if s.deadline.is_none() {
            s.deadline = Some(Instant::now() + Duration::from_secs(90));
        }
        s.snapshot.challenge_id = NEXT_CHALLENGE.fetch_add(1, Ordering::Relaxed);
        s.snapshot.kind = kind;
        s.snapshot.state = 1;
        s.snapshot.attempts_remaining = 3 - s.submissions;
        Ok(())
    }
    pub fn snapshot(&self) -> FileAuthSnapshot {
        let Ok(mut s) = self.state.lock() else {
            return FileAuthSnapshot::default();
        };
        Self::expire(&mut s);
        let mut result = s.snapshot;
        result.expires_in_ms = if s.closed {
            0
        } else {
            s.deadline
                .map(|v| v.saturating_duration_since(Instant::now()).as_millis() as u64)
                .unwrap_or(0)
        };
        result
    }
    pub fn submit(&self, challenge: u64, kind: u32, secret: &str) -> bool {
        let Ok(mut s) = self.state.lock() else {
            return false;
        };
        Self::expire(&mut s);
        let valid = match kind {
            1 => !secret.is_empty() && secret.len() <= 4096 && !secret.contains('\0'),
            2 => matches!(secret.len(), 6 | 8) && secret.bytes().all(|v| v.is_ascii_digit()),
            3 => secret.is_empty(),
            _ => false,
        };
        if !valid
            || s.closed
            || s.snapshot.state != 1
            || s.snapshot.challenge_id != challenge
            || challenge == 0
            || s.submissions >= 3
            || !(s.snapshot.kind == kind || (s.snapshot.kind == 1 && kind == 3))
        {
            return false;
        }
        s.submissions += 1;
        s.snapshot.attempts_remaining = 3 - s.submissions;
        s.snapshot.state = 2;
        s.pending = Some(FileAuthResponse {
            kind,
            secret: Secret::new(secret),
        });
        true
    }
    pub fn take(&self) -> io::Result<Option<FileAuthResponse>> {
        let mut s = self
            .state
            .lock()
            .map_err(|_| io::Error::other("auth lock"))?;
        Self::expire(&mut s);
        if s.closed {
            return Err(io::Error::new(
                if s.snapshot.state == 5 {
                    io::ErrorKind::TimedOut
                } else {
                    io::ErrorKind::Interrupted
                },
                "file authentication closed",
            ));
        }
        Ok(s.pending.take())
    }
    pub fn finish(&self, accepted: bool) {
        if let Ok(mut s) = self.state.lock() {
            Self::expire(&mut s);
            s.pending = None;
            if !s.closed {
                s.snapshot.state = if accepted { 3 } else { 4 };
                s.closed = true;
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interleaved_file_challenges_reject_cross_job_replay_and_wipe_cancelled_response() {
        assert_eq!(std::mem::size_of::<FileAuthSnapshot>(), 40);
        assert_eq!(
            std::mem::size_of::<crate::file_transfer::FileOperationResult>(),
            32
        );
        let a = FileAuthExchange::new(1);
        let b = FileAuthExchange::new(2);
        a.challenge(2).unwrap();
        b.challenge(2).unwrap();
        let ac = a.snapshot().challenge_id;
        let bc = b.snapshot().challenge_id;
        assert_ne!(ac, bc);
        assert!(!a.submit(bc, 2, "123456"));
        assert!(!b.submit(ac, 2, "123456"));
        assert!(b.submit(bc, 2, "654321"));
        assert!(a.submit(ac, 2, "123456"));
        assert!(!a.submit(ac, 2, "123456"));
        assert_eq!(b.take().unwrap().unwrap().secret.as_str(), "654321");
        a.finish(false);
        assert!(a.take().is_err());
        assert!(a.state.lock().unwrap().pending.is_none());
        b.challenge(2).unwrap();
        assert!(!b.submit(bc, 2, "654321"));
    }
    #[test]
    fn expiry_and_attempt_budget_do_not_extend_on_retry() {
        let a = FileAuthExchange::new(3);
        a.challenge(1).unwrap();
        let deadline = a.state.lock().unwrap().deadline;
        for _ in 0..3 {
            let id = a.snapshot().challenge_id;
            assert!(a.submit(id, 1, "secret"));
            a.take().unwrap();
            if a.snapshot().attempts_remaining > 0 {
                a.challenge(1).unwrap();
            }
        }
        assert!(a.challenge(1).is_err());
        assert_eq!(a.state.lock().unwrap().deadline, deadline);
        let b = FileAuthExchange::new(4);
        b.challenge(1).unwrap();
        let id = b.snapshot().challenge_id;
        b.state.lock().unwrap().deadline = Some(Instant::now() - Duration::from_secs(1));
        assert!(!b.submit(id, 1, "secret"));
        assert_eq!(b.snapshot().state, 5);
    }
}
