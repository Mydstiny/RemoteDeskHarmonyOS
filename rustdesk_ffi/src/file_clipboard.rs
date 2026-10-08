//! RustDesk Cliprdr on the authenticated desktop stream. This is independent of FileTransfer.
//! Wire descriptor layout follows FILEGROUPDESCRIPTORW (4 + n * 592 bytes).
use crate::clipboard_publication::{PublicationObservation, PublicationToken};
use crate::file_transfer::{DownloadSink, TransferJob, UploadSource};
use crate::protocol::message_proto::*;
use protobuf::Message as ProtoMessage;
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::io;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Condvar, Mutex, Weak,
};
use std::time::{Duration, Instant};

pub(crate) const MAX_ENTRIES: usize = 256;
const MAX_FILE_SIZE: u64 = 2 * 1024 * 1024 * 1024;
const MAX_REQUEST: usize = 4 * 1024 * 1024;
const MAX_PENDING_BYTES: usize = 8 * 1024 * 1024;
const FILETIME_EPOCH: u64 = 116_444_736_000_000_000;
const DESCRIPTOR_NAME: &str = "FileGroupDescriptorW";
const CONTENTS_NAME: &str = "FileContents";
const DESCRIPTOR_BASE: i32 = 49334;
const CONTENTS_FORMAT: i32 = 49267;
static NEXT_PUBLICATION: AtomicU64 = AtomicU64::new(1);
// IDs are never reused during a process lifetime, including after cancellation and source changes.
static NEXT_STREAM: AtomicU64 = AtomicU64::new(1);

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FileClipboardSnapshot {
    pub revision: u64,
    /// 0 disabled, 1 waiting formats, 2 waiting descriptors, 3 ready, 4 unsupported, 5 failed.
    pub state: u32,
    pub capable: u32,
    pub enabled: u32,
    pub entry_count: u32,
    pub diagnostic_code: u32,
}
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct FileClipboardPublication {
    pub publication_id: u64,
    /// 1 advertising, 2 ready for paste, 3 serving, 4 revoking, 5 revoked, 6 failed.
    pub state: u32,
    pub diagnostic_code: u32,
    /// Bytes read in response to peer requests, including repeated reads. Never remote completion.
    pub requested_bytes: u64,
    pub drained: u32,
}
#[derive(Clone, Debug)]
pub(crate) struct ClipboardFileEntry {
    pub name: String,
    pub is_directory: bool,
    pub size: u64,
    pub modified: u64,
}
pub(crate) struct ClipboardFileSource {
    pub entry: ClipboardFileEntry,
    pub source: Option<UploadSource>,
}
pub(crate) struct FileClipboardOutput {
    pub bytes: Vec<u8>,
    pub receipt: PublicationToken,
}
struct DescriptorRequest {
    revision: u64,
    format: i32,
    started: Instant,
}
struct LocalOffer {
    sources: Vec<ClipboardFileSource>,
    format: i32,
    descriptor: Vec<u8>,
    gate: Arc<AtomicBool>,
    published: Instant,
    descriptor_write: Option<PublicationObservation>,
    format_ack: bool,
    format_write: PublicationObservation,
    format_requested: bool,
    writes: Vec<PublicationObservation>,
    status: FileClipboardPublication,
    legacy_read_seen: bool,
    clip_data_ids: BTreeSet<i32>,
    revoke_at: Option<Instant>,
    revoke_ack: bool,
}
struct PendingResponse {
    revision: u64,
    expected: usize,
    result: Option<io::Result<Vec<u8>>>,
    gate: Arc<AtomicBool>,
}
struct State {
    controls: Weak<crate::control_inbox::ControlInbox>,
    capable: bool,
    requested_enabled: bool,
    enabled: bool,
    closed: bool,
    inbound_blocked: bool,
    outbound_blocked: bool,
    gate: Arc<AtomicBool>,
    snapshot: FileClipboardSnapshot,
    remote_entries: Vec<ClipboardFileEntry>,
    remote_format: Option<i32>,
    descriptor_request: Option<DescriptorRequest>,
    pending: BTreeMap<i32, PendingResponse>,
    offers: BTreeMap<u64, LocalOffer>,
    active_offer: Option<u64>,
    next_format: i32,
    retired_clip_ids: BTreeSet<i32>,
    ever_revoked: bool,
    outgoing: VecDeque<FileClipboardOutput>,
    writes: Vec<(PublicationObservation, usize)>,
}
pub(crate) struct FileClipboard {
    state: Mutex<State>,
    wake: Condvar,
    clipboard: Arc<Mutex<crate::ClipboardSnapshot>>,
}
fn err(kind: io::ErrorKind, message: &'static str) -> io::Error {
    io::Error::new(kind, message)
}
fn message(clip: Cliprdr) -> Message {
    let mut m = Message::new();
    m.set_cliprdr(clip);
    m
}
fn with_clip(union: Cliprdr_oneof_union) -> Message {
    let mut c = Cliprdr::new();
    c.union = Some(union);
    message(c)
}
fn contents_failure(stream: i32) -> Message {
    let mut response = CliprdrFileContentsResponse::new();
    response.set_stream_id(stream);
    response.set_msg_flags(2);
    with_clip(Cliprdr_oneof_union::file_contents_response(response))
}
fn format_failure() -> Message {
    let mut response = CliprdrServerFormatDataResponse::new();
    response.set_msg_flags(2);
    with_clip(Cliprdr_oneof_union::format_data_response(response))
}
fn normalized_name(name: &str) -> io::Result<String> {
    let value = name.replace('\\', "/");
    if value.is_empty()
        || value.starts_with('/')
        || value.encode_utf16().count() > 259
        || value.chars().any(|c| {
            c == '\0' || c.is_control() || matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|')
        })
        || value
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == ".." || p.ends_with(' ') || p.ends_with('.'))
    {
        return Err(err(
            io::ErrorKind::InvalidInput,
            "unsafe clipboard filename",
        ));
    }
    for part in value.split('/') {
        let stem = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CLOCK$")
            || (stem.len() == 4
                && (stem.starts_with("COM") || stem.starts_with("LPT"))
                && matches!(stem.as_bytes()[3], b'1'..=b'9'))
        {
            return Err(err(
                io::ErrorKind::InvalidInput,
                "reserved clipboard filename",
            ));
        }
    }
    Ok(value)
}
fn validate_entries(entries: &[ClipboardFileEntry]) -> io::Result<()> {
    if entries.is_empty() || entries.len() > MAX_ENTRIES {
        return Err(err(
            io::ErrorKind::InvalidInput,
            "clipboard file count limit",
        ));
    }
    let mut names = BTreeMap::new();
    let mut total = 0u64;
    for entry in entries {
        let name = normalized_name(&entry.name)?;
        if name != entry.name
            || entry.size > MAX_FILE_SIZE
            || (entry.is_directory && entry.size != 0)
        {
            return Err(err(io::ErrorKind::InvalidInput, "clipboard metadata limit"));
        }
        let key = name.to_lowercase();
        if names.insert(key, entry.is_directory).is_some() {
            return Err(err(
                io::ErrorKind::InvalidInput,
                "clipboard filename collision",
            ));
        }
        total = total
            .checked_add(entry.size)
            .ok_or_else(|| err(io::ErrorKind::InvalidInput, "clipboard batch size overflow"))?;
    }
    if total > MAX_FILE_SIZE {
        return Err(err(
            io::ErrorKind::InvalidInput,
            "clipboard batch size limit",
        ));
    }
    for name in names.keys() {
        let mut prefix = String::new();
        let parts = name.split('/').collect::<Vec<_>>();
        for part in &parts[..parts.len() - 1] {
            if !prefix.is_empty() {
                prefix.push('/');
            }
            prefix.push_str(part);
            if names.get(&prefix) != Some(&true) {
                return Err(err(
                    io::ErrorKind::InvalidInput,
                    "clipboard missing parent directory",
                ));
            }
        }
    }
    Ok(())
}
fn build_descriptors(entries: &[ClipboardFileEntry]) -> io::Result<Vec<u8>> {
    validate_entries(entries)?;
    let mut bytes = vec![0u8; 4 + entries.len() * 592];
    bytes[..4].copy_from_slice(&(entries.len() as u32).to_le_bytes());
    for (index, entry) in entries.iter().enumerate() {
        let b = &mut bytes[4 + index * 592..4 + (index + 1) * 592];
        b[..4].copy_from_slice(&0x0000_4064u32.to_le_bytes()); // attributes, write time, size, progress UI
        b[36..40]
            .copy_from_slice(&(if entry.is_directory { 0x10u32 } else { 0x80u32 }).to_le_bytes());
        let time = entry
            .modified
            .checked_mul(10_000_000)
            .and_then(|v| v.checked_add(FILETIME_EPOCH))
            .ok_or_else(|| err(io::ErrorKind::InvalidInput, "clipboard timestamp overflow"))?;
        b[56..64].copy_from_slice(&time.to_le_bytes());
        b[64..68].copy_from_slice(&((entry.size >> 32) as u32).to_le_bytes());
        b[68..72].copy_from_slice(&(entry.size as u32).to_le_bytes());
        for (i, unit) in entry.name.replace('/', "\\").encode_utf16().enumerate() {
            b[72 + i * 2..74 + i * 2].copy_from_slice(&unit.to_le_bytes());
        }
    }
    Ok(bytes)
}
fn parse_descriptors(bytes: &[u8]) -> io::Result<Vec<ClipboardFileEntry>> {
    if bytes.len() < 4 {
        return Err(err(
            io::ErrorKind::InvalidData,
            "clipboard descriptor header",
        ));
    }
    let count = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    if count == 0 || count > MAX_ENTRIES || bytes.len() != 4 + count * 592 {
        return Err(err(
            io::ErrorKind::InvalidData,
            "clipboard descriptor length",
        ));
    }
    let mut entries = Vec::with_capacity(count);
    for b in bytes[4..].chunks_exact(592) {
        let flags = u32::from_le_bytes(b[..4].try_into().unwrap());
        let attributes = u32::from_le_bytes(b[36..40].try_into().unwrap());
        // Directories are represented explicitly. Reparse points / symlinks and unknown sizes are unsupported.
        if flags & 4 == 0 || flags & 0x40 == 0 || attributes & 0x400 != 0 {
            return Err(err(
                io::ErrorKind::InvalidData,
                "unsupported clipboard descriptor",
            ));
        }
        let mut name = Vec::new();
        let mut terminated = false;
        for pair in b[72..].chunks_exact(2) {
            let value = u16::from_le_bytes(pair.try_into().unwrap());
            if value == 0 {
                terminated = true;
                break;
            }
            name.push(value);
        }
        if !terminated {
            return Err(err(
                io::ErrorKind::InvalidData,
                "clipboard filename unterminated",
            ));
        }
        let name = normalized_name(
            &String::from_utf16(&name)
                .map_err(|_| err(io::ErrorKind::InvalidData, "clipboard filename utf16"))?,
        )?;
        let time = u64::from_le_bytes(b[56..64].try_into().unwrap());
        let modified = if flags & 0x20 != 0 {
            time.checked_sub(FILETIME_EPOCH)
                .ok_or_else(|| err(io::ErrorKind::InvalidData, "clipboard timestamp"))?
                / 10_000_000
        } else {
            0
        };
        let size = ((u32::from_le_bytes(b[64..68].try_into().unwrap()) as u64) << 32)
            | u32::from_le_bytes(b[68..72].try_into().unwrap()) as u64;
        entries.push(ClipboardFileEntry {
            name,
            is_directory: attributes & 0x10 != 0,
            size,
            modified,
        });
    }
    validate_entries(&entries)?;
    Ok(entries)
}

// The upstream field is a one-level JSON dictionary. Parse tokens, rather than searching inside
// unrelated strings, so a nested/quoted has_file_clipboard value cannot enable a capability.
fn json_file_capability(input: &str) -> bool {
    fn whitespace(b: &[u8], p: &mut usize) {
        while *p < b.len() && b[*p].is_ascii_whitespace() {
            *p += 1;
        }
    }
    fn string<'a>(b: &'a [u8], p: &mut usize) -> Option<&'a [u8]> {
        if b.get(*p) != Some(&b'"') {
            return None;
        }
        *p += 1;
        let start = *p;
        while let Some(&v) = b.get(*p) {
            if v == b'"' {
                let out = &b[start..*p];
                *p += 1;
                return Some(out);
            }
            if v < 0x20 {
                return None;
            }
            if v == b'\\' {
                *p += 1;
                let escaped = *b.get(*p)?;
                if escaped == b'u' {
                    for _ in 0..4 {
                        *p += 1;
                        if !b.get(*p)?.is_ascii_hexdigit() {
                            return None;
                        }
                    }
                } else if !matches!(
                    escaped,
                    b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't'
                ) {
                    return None;
                }
            }
            *p += 1;
        }
        None
    }
    fn value(b: &[u8], p: &mut usize, depth: usize) -> Option<()> {
        if depth > 16 {
            return None;
        }
        whitespace(b, p);
        match *b.get(*p)? {
            b'"' => {
                string(b, p)?;
            }
            b'{' | b'[' => {
                let object = b[*p] == b'{';
                let close = if object { b'}' } else { b']' };
                *p += 1;
                whitespace(b, p);
                if b.get(*p) == Some(&close) {
                    *p += 1;
                    return Some(());
                }
                loop {
                    if object {
                        whitespace(b, p);
                        string(b, p)?;
                        whitespace(b, p);
                        if b.get(*p) != Some(&b':') {
                            return None;
                        }
                        *p += 1;
                    }
                    value(b, p, depth + 1)?;
                    whitespace(b, p);
                    if b.get(*p) == Some(&close) {
                        *p += 1;
                        break;
                    }
                    if b.get(*p) != Some(&b',') {
                        return None;
                    }
                    *p += 1;
                }
            }
            _ => {
                let start = *p;
                while *p < b.len()
                    && !matches!(b[*p], b',' | b']' | b'}' | b' ' | b'\r' | b'\n' | b'\t')
                {
                    *p += 1;
                }
                let token = std::str::from_utf8(&b[start..*p]).ok()?;
                if !matches!(token, "true" | "false" | "null") && token.parse::<f64>().is_err() {
                    return None;
                }
            }
        }
        Some(())
    }
    if input.len() > 65536 {
        return false;
    }
    let b = input.as_bytes();
    let mut p = 0;
    whitespace(b, &mut p);
    if b.get(p) != Some(&b'{') {
        return false;
    }
    p += 1;
    let mut found = None;
    loop {
        whitespace(b, &mut p);
        if b.get(p) == Some(&b'}') {
            p += 1;
            break;
        }
        let Some(key) = string(b, &mut p) else {
            return false;
        };
        whitespace(b, &mut p);
        if b.get(p) != Some(&b':') {
            return false;
        }
        p += 1;
        whitespace(b, &mut p);
        let start = p;
        if value(b, &mut p, 0).is_none() {
            return false;
        }
        if key == b"has_file_clipboard" {
            if found.is_some() {
                return false;
            }
            found = Some(&b[start..p] == b"true");
        }
        whitespace(b, &mut p);
        if b.get(p) == Some(&b'}') {
            p += 1;
            break;
        }
        if b.get(p) != Some(&b',') {
            return false;
        }
        p += 1;
    }
    whitespace(b, &mut p);
    p == b.len() && found == Some(true)
}
fn version_at_least(version: &str, minimum: (u32, u32, u32)) -> bool {
    let parts = version
        .split('.')
        .take(3)
        .map(|v| v.parse::<u32>().ok())
        .collect::<Option<Vec<_>>>();
    parts.is_some_and(|v| v.len() == 3 && (v[0], v[1], v[2]) >= minimum)
}
impl FileClipboard {
    pub fn new(clipboard: Arc<Mutex<crate::ClipboardSnapshot>>) -> Self {
        Self {
            clipboard,
            wake: Condvar::new(),
            state: Mutex::new(State {
                controls: Weak::new(),
                capable: false,
                requested_enabled: false,
                enabled: false,
                closed: false,
                inbound_blocked: false,
                outbound_blocked: false,
                gate: Arc::new(AtomicBool::new(true)),
                snapshot: FileClipboardSnapshot::default(),
                remote_entries: Vec::new(),
                remote_format: None,
                descriptor_request: None,
                pending: BTreeMap::new(),
                offers: BTreeMap::new(),
                active_offer: None,
                next_format: DESCRIPTOR_BASE,
                retired_clip_ids: BTreeSet::new(),
                ever_revoked: false,
                outgoing: VecDeque::new(),
                writes: Vec::new(),
            }),
        }
    }
    pub fn bind_controls(&self, controls: &Arc<crate::control_inbox::ControlInbox>) {
        if let Ok(mut s) = self.state.lock() {
            s.controls = Arc::downgrade(controls);
        }
    }
    fn allowed(s: &State) -> bool {
        let Some(controls) = s.controls.upgrade() else {
            return false;
        };
        let permissions = controls.permission_snapshot();
        let mask =
            crate::control_inbox::PERMISSION_CLIPBOARD | crate::control_inbox::PERMISSION_FILE;
        !s.closed
            && !controls.shutdown_requested()
            && permissions.known_mask & mask & !permissions.enabled_mask == 0
    }
    fn queue(
        s: &mut State,
        msg: Message,
        gate: Arc<AtomicBool>,
        permission_mask: u32,
    ) -> io::Result<PublicationObservation> {
        s.writes.retain(|(write, _)| write.state() == 1);
        let bytes = msg.write_to_bytes().map_err(|_| {
            err(
                io::ErrorKind::InvalidData,
                "clipboard message serialization",
            )
        })?;
        let pending_bytes: usize = s.writes.iter().map(|(_, bytes)| *bytes).sum();
        if s.writes.len() >= 64
            || bytes.len() > MAX_REQUEST + 512
            || pending_bytes.saturating_add(bytes.len()) > MAX_PENDING_BYTES
        {
            return Err(err(io::ErrorKind::WouldBlock, "clipboard output budget"));
        }
        let (observation, receipt) = PublicationToken::for_file_clipboard(
            s.controls.clone(),
            permission_mask,
            Arc::downgrade(&gate),
        );
        s.writes.push((observation.clone(), bytes.len()));
        s.outgoing.push_back(FileClipboardOutput { bytes, receipt });
        Ok(observation)
    }
    fn queue_clip(s: &mut State, msg: Message) -> io::Result<PublicationObservation> {
        Self::queue(
            s,
            msg,
            s.gate.clone(),
            crate::control_inbox::PERMISSION_CLIPBOARD | crate::control_inbox::PERMISSION_FILE,
        )
    }
    fn option(s: &mut State, enabled: bool) -> io::Result<()> {
        let mut option = OptionMessage::new();
        option.set_enable_file_transfer(if enabled {
            OptionMessage_BoolOption::Yes
        } else {
            OptionMessage_BoolOption::No
        });
        let mut misc = Misc::new();
        misc.set_option(option);
        let mut msg = Message::new();
        msg.set_misc(misc);
        Self::queue(s, msg, s.gate.clone(), 0)?;
        if enabled {
            Self::queue_clip(
                s,
                with_clip(Cliprdr_oneof_union::ready(CliprdrMonitorReady::new())),
            )?;
        }
        Ok(())
    }
    pub fn update_peer(&self, info: &PeerInfo) {
        if let Ok(mut s) = self.state.lock() {
            let platform = info.get_platform();
            let supported_version = match platform {
                "Windows" | "Linux" => version_at_least(info.get_version(), (1, 3, 8)),
                "Mac OS" | "MacOS" => version_at_least(info.get_version(), (1, 3, 9)),
                _ => false,
            };
            s.capable = supported_version && json_file_capability(info.get_platform_additions());
            s.snapshot.capable = s.capable as u32;
            if !s.capable {
                Self::invalidate(&mut s, 1, false);
            } else if s.requested_enabled && !s.enabled && Self::allowed(&s) {
                s.enabled = true;
                s.snapshot.enabled = 1;
                s.snapshot.state = 1;
                if Self::option(&mut s, true).is_err() {
                    Self::invalidate(&mut s, 2, false);
                }
            }
        }
    }
    pub fn configure(&self, enabled: bool) -> bool {
        let Ok(mut s) = self.state.lock() else {
            return false;
        };
        if s.closed {
            return false;
        }
        s.requested_enabled = enabled;
        if !enabled {
            Self::invalidate(&mut s, 0, false);
            let _ = Self::option(&mut s, false);
            self.wake.notify_all();
            return true;
        }
        if !Self::allowed(&s) {
            return false;
        }
        if !s.capable {
            return true;
        } // Wait for authenticated PeerInfo, never infer negotiation success.
        if !s.enabled {
            s.enabled = true;
            s.snapshot.enabled = 1;
            s.snapshot.state = if s.inbound_blocked { 5 } else { 1 };
            if Self::option(&mut s, true).is_err() {
                Self::invalidate(&mut s, 2, false);
                return false;
            }
        }
        true
    }
    fn fail_pending(s: &mut State, kind: io::ErrorKind) {
        for response in s.pending.values_mut() {
            response.gate.store(false, Ordering::Release);
            if response.result.is_none() {
                response.result = Some(Err(err(kind, "clipboard source invalidated")));
            }
        }
    }
    fn invalidate(s: &mut State, diagnostic: u32, closed: bool) {
        s.gate.store(false, Ordering::Release);
        s.outgoing.clear();
        s.gate = Arc::new(AtomicBool::new(!closed));
        s.enabled = false;
        s.closed |= closed;
        s.snapshot.enabled = 0;
        s.snapshot.state = if diagnostic == 0 { 0 } else { 5 };
        s.snapshot.diagnostic_code = diagnostic;
        s.remote_entries.clear();
        s.snapshot.entry_count = 0;
        s.remote_format = None;
        if s.descriptor_request.is_some() {
            s.inbound_blocked = true;
        }
        Self::fail_pending(s, io::ErrorKind::Interrupted);
        if s.active_offer.is_some() {
            s.outbound_blocked = true;
        }
        for offer in s.offers.values_mut() {
            if !matches!(offer.status.state, 5 | 6) {
                offer.status.state = 6;
                offer.status.diagnostic_code = diagnostic;
            }
            offer.gate.store(false, Ordering::Release);
        }
    }
    pub fn permission_denied(&self) {
        if let Ok(mut s) = self.state.lock() {
            Self::invalidate(&mut s, 3, false);
        }
        self.wake.notify_all();
    }
    pub fn close(&self) {
        if let Ok(mut s) = self.state.lock() {
            Self::invalidate(&mut s, 4, true);
        }
        self.wake.notify_all();
    }
    fn poll(s: &mut State) {
        s.writes.retain(|(write, _)| write.state() == 1);
        if s.descriptor_request
            .as_ref()
            .is_some_and(|request| request.started.elapsed() > Duration::from_secs(10))
        {
            s.inbound_blocked = true;
            s.snapshot.state = 5;
            s.snapshot.diagnostic_code = 5;
            s.remote_entries.clear();
            s.snapshot.entry_count = 0;
            Self::fail_pending(s, io::ErrorKind::TimedOut);
        }
        let mut release_active = false;
        for (id, offer) in &mut s.offers {
            offer.writes.retain(|write| write.state() == 1);
            if matches!(offer.status.state, 1 | 2 | 3) {
                let descriptor_written = offer
                    .descriptor_write
                    .as_ref()
                    .is_some_and(|v| v.state() == 2);
                let descriptor_failed = offer
                    .descriptor_write
                    .as_ref()
                    .is_some_and(|v| v.state() == 3);
                if descriptor_failed
                    || (offer.status.state == 1
                        && offer.published.elapsed() > Duration::from_secs(10))
                    || offer.published.elapsed() > Duration::from_secs(10 * 60)
                {
                    offer.status.state = 6;
                    offer.status.diagnostic_code = 6;
                    offer.gate.store(false, Ordering::Release);
                    s.outbound_blocked = true;
                } else if offer.status.state == 1
                    && ((offer.format_ack && offer.format_write.state() == 2)
                        || (offer.format_requested && descriptor_written))
                {
                    offer.status.state = 2;
                }
            }
            if offer.status.state == 4 {
                if offer.revoke_ack && offer.writes.is_empty() {
                    offer.status.state = 5;
                } else if offer
                    .revoke_at
                    .is_some_and(|v| v.elapsed() > Duration::from_secs(10))
                {
                    offer.status.state = 6;
                    offer.status.diagnostic_code = 7;
                    s.outbound_blocked = true;
                }
            }
            if matches!(offer.status.state, 5 | 6) && offer.writes.is_empty() {
                offer.sources.clear();
                offer.descriptor.clear();
                offer.status.drained = 1;
                if s.active_offer == Some(*id) {
                    release_active = true;
                }
            }
        }
        if release_active {
            s.active_offer = None;
        }
    }
    pub fn snapshot(&self) -> FileClipboardSnapshot {
        let Ok(mut s) = self.state.lock() else {
            return FileClipboardSnapshot::default();
        };
        Self::poll(&mut s);
        let mut snapshot = s.snapshot;
        if !Self::allowed(&s) {
            snapshot.enabled = 0;
            if snapshot.state == 3 {
                snapshot.state = 5;
            }
        }
        snapshot
    }
    pub fn entries(&self, revision: u64) -> Option<Vec<ClipboardFileEntry>> {
        let mut s = self.state.lock().ok()?;
        Self::poll(&mut s);
        if !Self::allowed(&s)
            || !s.enabled
            || s.snapshot.revision != revision
            || s.snapshot.state != 3
        {
            return None;
        }
        Some(s.remote_entries.clone())
    }
    pub fn take_outputs(&self) -> Vec<FileClipboardOutput> {
        let Ok(mut s) = self.state.lock() else {
            return Vec::new();
        };
        Self::poll(&mut s);
        if s.closed {
            s.outgoing.clear();
            return Vec::new();
        }
        (0..2).filter_map(|_| s.outgoing.pop_front()).collect()
    }
    fn request_descriptor(s: &mut State) -> io::Result<()> {
        if s.inbound_blocked || !s.enabled || s.descriptor_request.is_some() {
            return Ok(());
        }
        let Some(format) = s.remote_format else {
            return Ok(());
        };
        let mut request = CliprdrServerFormatDataRequest::new();
        request.set_requested_format_id(format);
        Self::queue_clip(
            s,
            with_clip(Cliprdr_oneof_union::format_data_request(request)),
        )?;
        s.descriptor_request = Some(DescriptorRequest {
            revision: s.snapshot.revision,
            format,
            started: Instant::now(),
        });
        Ok(())
    }
    fn observe_text_locked(&self, s: &mut State, content: Option<&[u8]>) {
        if let Ok(mut clipboard) = self.clipboard.lock() {
            clipboard.update(content);
            s.snapshot.revision = clipboard.revision;
        }
        s.remote_entries.clear();
        s.remote_format = None;
        s.snapshot.entry_count = 0;
        s.snapshot.state = if s.enabled { 1 } else { 0 };
        Self::fail_pending(s, io::ErrorKind::Interrupted);
        if let Some(id) = s.active_offer {
            let _ = Self::revoke(s, id);
        }
    }
    pub fn observe_text(&self, content: Option<&[u8]>) {
        if let Ok(mut s) = self.state.lock() {
            self.observe_text_locked(&mut s, content);
        }
        self.wake.notify_all();
    }
    pub fn publish(&self, sources: Vec<ClipboardFileSource>) -> io::Result<u64> {
        let entries = sources
            .iter()
            .map(|source| source.entry.clone())
            .collect::<Vec<_>>();
        let descriptor = build_descriptors(&entries)?;
        for source in &sources {
            match (&source.source, source.entry.is_directory) {
                (Some(file), false) => {
                    file.validate_unchanged()?;
                    if file.size() != source.entry.size || file.modified() != source.entry.modified
                    {
                        return Err(err(
                            io::ErrorKind::InvalidInput,
                            "clipboard source metadata mismatch",
                        ));
                    }
                }
                (None, true) => {}
                _ => {
                    return Err(err(
                        io::ErrorKind::InvalidInput,
                        "clipboard source kind mismatch",
                    ))
                }
            }
        }
        let mut s = self
            .state
            .lock()
            .map_err(|_| err(io::ErrorKind::Other, "clipboard lock"))?;
        Self::poll(&mut s);
        if !Self::allowed(&s) || !s.enabled || !s.capable || s.outbound_blocked {
            return Err(err(
                io::ErrorKind::PermissionDenied,
                "file clipboard unavailable or requires reconnect",
            ));
        }
        if s.active_offer.is_some() {
            return Err(err(
                io::ErrorKind::WouldBlock,
                "revoke previous clipboard publication first",
            ));
        }
        if s.offers.len() >= 16 {
            let old = s
                .offers
                .iter()
                .find(|(_, offer)| offer.status.drained != 0)
                .map(|(id, _)| *id);
            if let Some(id) = old {
                s.offers.remove(&id);
            } else {
                return Err(err(
                    io::ErrorKind::WouldBlock,
                    "clipboard publication registry full",
                ));
            }
        }
        if s.next_format >= 65535 {
            return Err(err(
                io::ErrorKind::Other,
                "clipboard format namespace exhausted",
            ));
        }
        let format = s.next_format;
        s.next_format += 1;
        let id = NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed);
        let gate = Arc::new(AtomicBool::new(true));
        let mut list = CliprdrServerFormatList::new();
        for (format_id, name) in [(format, DESCRIPTOR_NAME), (CONTENTS_FORMAT, CONTENTS_NAME)] {
            let mut entry = CliprdrFormat::new();
            entry.set_id(format_id);
            entry.set_format(name.to_owned());
            list.mut_formats().push(entry);
        }
        let write = Self::queue(
            &mut s,
            with_clip(Cliprdr_oneof_union::format_list(list)),
            gate.clone(),
            crate::control_inbox::PERMISSION_CLIPBOARD | crate::control_inbox::PERMISSION_FILE,
        )?;
        s.offers.insert(
            id,
            LocalOffer {
                sources,
                format,
                descriptor,
                gate,
                published: Instant::now(),
                descriptor_write: None,
                format_ack: false,
                format_requested: false,
                format_write: write.clone(),
                writes: vec![write],
                status: FileClipboardPublication {
                    publication_id: id,
                    state: 1,
                    ..Default::default()
                },
                legacy_read_seen: false,
                clip_data_ids: BTreeSet::new(),
                revoke_at: None,
                revoke_ack: false,
            },
        );
        s.active_offer = Some(id);
        Ok(id)
    }
    pub fn publication(&self, id: u64) -> FileClipboardPublication {
        let Ok(mut s) = self.state.lock() else {
            return FileClipboardPublication::default();
        };
        Self::poll(&mut s);
        s.offers.get(&id).map(|v| v.status).unwrap_or_default()
    }
    fn revoke(s: &mut State, id: u64) -> io::Result<()> {
        let offer = s
            .offers
            .get_mut(&id)
            .ok_or_else(|| err(io::ErrorKind::NotFound, "clipboard publication not found"))?;
        if matches!(offer.status.state, 4 | 5 | 6) {
            return Ok(());
        }
        offer.gate.store(false, Ordering::Release);
        offer.status.state = 4;
        offer.revoke_at = Some(Instant::now());
        // Cliprdr has no Lock/Unlock handshake binding even a first-seen clip_data_id
        // to a descriptor publication. A delayed old paste can introduce a new ID
        // after revocation, so no successor FD may be offered on this carrier.
        s.outbound_blocked = true;
        offer.status.diagnostic_code = 8;
        s.retired_clip_ids
            .extend(offer.clip_data_ids.iter().copied());
        s.ever_revoked = true;
        Self::queue_clip(
            s,
            with_clip(Cliprdr_oneof_union::format_list(
                CliprdrServerFormatList::new(),
            )),
        )?;
        Ok(())
    }
    pub fn revoke_publication(&self, id: u64) -> bool {
        self.state
            .lock()
            .map(|mut s| Self::revoke(&mut s, id).is_ok())
            .unwrap_or(false)
    }
    pub fn revoke_local_source(&self) {
        if let Ok(mut s) = self.state.lock() {
            if let Some(id) = s.active_offer {
                let _ = Self::revoke(&mut s, id);
            }
        }
    }
    fn process_format_list(&self, s: &mut State, list: &CliprdrServerFormatList) -> io::Result<()> {
        let mut descriptor = None;
        let mut contents = false;
        let mut valid = list.get_formats().len() <= 64;
        let mut ids = BTreeSet::new();
        for format in list.get_formats() {
            if format.get_id() <= 0
                || format.get_format().len() > 256
                || !ids.insert(format.get_id())
            {
                valid = false;
                break;
            }
            if format.get_format() == DESCRIPTOR_NAME {
                if descriptor.replace(format.get_id()).is_some() {
                    valid = false;
                }
            }
            if format.get_format() == CONTENTS_NAME {
                contents = true;
            }
        }
        let files = valid && descriptor.is_some() && contents;
        let mut clipboard = self
            .clipboard
            .lock()
            .map_err(|_| err(io::ErrorKind::Other, "clipboard snapshot lock"))?;
        if files {
            clipboard.update_files();
        } else if list.get_formats().is_empty() {
            clipboard.update(Some(&[]));
        } else {
            clipboard.update(None);
        }
        s.snapshot.revision = clipboard.revision;
        drop(clipboard);
        s.remote_entries.clear();
        s.snapshot.entry_count = 0;
        s.remote_format = if files { descriptor } else { None };
        s.snapshot.state = if files { 2 } else { 4 };
        s.snapshot.diagnostic_code = if files { 0 } else { 9 };
        Self::fail_pending(s, io::ErrorKind::Interrupted);
        if let Some(id) = s.active_offer {
            let _ = Self::revoke(s, id);
        }
        if !s.enabled || !Self::allowed(s) || s.inbound_blocked {
            return Ok(());
        }
        let mut response = CliprdrServerFormatListResponse::new();
        response.set_msg_flags(if files { 1 } else { 2 });
        Self::queue_clip(
            s,
            with_clip(Cliprdr_oneof_union::format_list_response(response)),
        )?;
        Self::request_descriptor(s)
    }
    fn serve_contents(s: &mut State, request: &CliprdrFileContentsRequest) -> io::Result<()> {
        let stream = request.get_stream_id();
        let Some(id) = s.active_offer else {
            Self::queue_clip(s, contents_failure(stream))?;
            return Ok(());
        };
        if !request.get_have_clip_data_id() && s.ever_revoked {
            if let Some(offer) = s.offers.get_mut(&id) {
                offer.status.state = 6;
                offer.status.diagnostic_code = 8;
                offer.gate.store(false, Ordering::Release);
            }
            s.outbound_blocked = true;
            Self::queue_clip(s, contents_failure(stream))?;
            return Ok(());
        }
        if request.get_have_clip_data_id()
            && s.retired_clip_ids.contains(&request.get_clip_data_id())
        {
            Self::queue_clip(s, contents_failure(stream))?;
            return Ok(());
        }
        let response = (|| -> io::Result<(Message, Arc<AtomicBool>)> {
            let offer = s
                .offers
                .get_mut(&id)
                .ok_or_else(|| err(io::ErrorKind::NotFound, "clipboard publication missing"))?;
            if !matches!(offer.status.state, 1 | 2 | 3)
                || !offer.format_requested
                || !offer.gate.load(Ordering::Acquire)
            {
                return Err(err(
                    io::ErrorKind::Interrupted,
                    "clipboard publication inactive",
                ));
            }
            if request.get_list_index() < 0
                || request.get_cb_requested() < 0
                || !matches!(request.get_dw_flags(), 1 | 2)
            {
                return Err(err(
                    io::ErrorKind::InvalidInput,
                    "invalid clipboard range request",
                ));
            }
            let source = offer
                .sources
                .get(request.get_list_index() as usize)
                .and_then(|source| source.source.as_ref())
                .ok_or_else(|| err(io::ErrorKind::InvalidInput, "clipboard file index"))?;
            if request.get_have_clip_data_id() {
                if offer.clip_data_ids.len() >= 16
                    && !offer.clip_data_ids.contains(&request.get_clip_data_id())
                {
                    return Err(err(io::ErrorKind::InvalidInput, "clipboard data id limit"));
                }
                offer.clip_data_ids.insert(request.get_clip_data_id());
            } else {
                offer.legacy_read_seen = true;
            }
            source.validate_unchanged()?;
            let mut response = CliprdrFileContentsResponse::new();
            response.set_stream_id(stream);
            response.set_msg_flags(1);
            if request.get_dw_flags() == 1 {
                response.set_requested_data(source.size().to_le_bytes().to_vec());
            } else {
                let offset = ((request.get_n_position_high() as u32 as u64) << 32)
                    | request.get_n_position_low() as u32 as u64;
                let requested = request.get_cb_requested() as usize;
                if requested == 0 || requested > MAX_REQUEST || offset > source.size() {
                    return Err(err(io::ErrorKind::InvalidInput, "clipboard range limit"));
                }
                let length = requested.min((source.size() - offset) as usize);
                let mut data = vec![0u8; length];
                let mut read = 0;
                while read < length {
                    let n = source.read_at(offset + read as u64, &mut data[read..])?;
                    if n == 0 {
                        return Err(err(
                            io::ErrorKind::UnexpectedEof,
                            "clipboard source truncated",
                        ));
                    }
                    read += n;
                }
                source.validate_unchanged()?;
                offer.status.requested_bytes =
                    offer.status.requested_bytes.saturating_add(read as u64);
                response.set_requested_data(data);
            }
            offer.status.state = 3;
            Ok((
                with_clip(Cliprdr_oneof_union::file_contents_response(response)),
                offer.gate.clone(),
            ))
        })();
        match response {
            Ok((message, gate)) => {
                let write = Self::queue(
                    s,
                    message,
                    gate,
                    crate::control_inbox::PERMISSION_CLIPBOARD
                        | crate::control_inbox::PERMISSION_FILE,
                )?;
                if let Some(offer) = s.offers.get_mut(&id) {
                    offer.writes.push(write);
                }
            }
            Err(error) => {
                if !matches!(
                    error.kind(),
                    io::ErrorKind::InvalidInput | io::ErrorKind::Interrupted
                ) {
                    if let Some(offer) = s.offers.get_mut(&id) {
                        offer.status.state = 6;
                        offer.status.diagnostic_code = 14;
                        offer.gate.store(false, Ordering::Release);
                    }
                    s.outbound_blocked = true;
                }
                Self::queue_clip(s, contents_failure(stream))?;
            }
        }
        Ok(())
    }
    pub fn handle_message(&self, clip: &Cliprdr) {
        let Ok(mut s) = self.state.lock() else {
            return;
        };
        Self::poll(&mut s);
        // FormatList is a source event even when the capability/permission is disabled.
        // This prevents an older local file URI from hijacking a newly copied remote object.
        if let Some(Cliprdr_oneof_union::format_list(list)) = &clip.union {
            if self.process_format_list(&mut s, list).is_err() {
                Self::invalidate(&mut s, 10, false);
            }
            self.wake.notify_all();
            return;
        }
        if let Some(Cliprdr_oneof_union::try_empty(_)) = &clip.union {
            let owns_files = self.clipboard.lock().map(|v| v.files).unwrap_or(false);
            if owns_files {
                self.observe_text_locked(&mut s, Some(&[]));
            }
            drop(s);
            self.wake.notify_all();
            return;
        }
        if !s.enabled || !Self::allowed(&s) {
            return;
        }
        let result = (|| -> io::Result<()> {
            match &clip.union {
                Some(Cliprdr_oneof_union::ready(_)) => {}
                Some(Cliprdr_oneof_union::format_list_response(response)) => {
                    if let Some(id) = s.active_offer {
                        if let Some(offer) = s.offers.get_mut(&id) {
                            if response.get_msg_flags() != 1 {
                                offer.gate.store(false, Ordering::Release);
                                offer.status.state = 6;
                                offer.status.diagnostic_code = 11;
                                s.outbound_blocked = true;
                            } else if offer.status.state == 4 {
                                if !offer.format_ack && !offer.format_requested {
                                    offer.format_ack = true;
                                } else {
                                    offer.revoke_ack = true;
                                }
                            } else {
                                offer.format_ack = true;
                            }
                        }
                    }
                }
                Some(Cliprdr_oneof_union::format_data_request(request)) => {
                    let offer_data = s.active_offer.and_then(|id| {
                        s.offers
                            .get(&id)
                            .filter(|offer| {
                                matches!(offer.status.state, 1 | 2 | 3)
                                    && offer.format == request.get_requested_format_id()
                            })
                            .map(|offer| (id, offer.descriptor.clone(), offer.gate.clone()))
                    });
                    if let Some((id, data, gate)) = offer_data {
                        let mut response = CliprdrServerFormatDataResponse::new();
                        response.set_msg_flags(1);
                        response.set_format_data(data);
                        let write = Self::queue(
                            &mut s,
                            with_clip(Cliprdr_oneof_union::format_data_response(response)),
                            gate,
                            crate::control_inbox::PERMISSION_CLIPBOARD
                                | crate::control_inbox::PERMISSION_FILE,
                        )?;
                        if let Some(offer) = s.offers.get_mut(&id) {
                            offer.format_requested = true;
                            offer.descriptor_write = Some(write.clone());
                            offer.writes.push(write);
                        }
                    } else {
                        Self::queue_clip(&mut s, format_failure())?;
                    }
                }
                Some(Cliprdr_oneof_union::format_data_response(response)) => {
                    if s.inbound_blocked {
                        return Ok(());
                    }
                    let Some(request) = s.descriptor_request.take() else {
                        return Ok(());
                    };
                    if request.revision == s.snapshot.revision
                        && Some(request.format) == s.remote_format
                    {
                        if response.get_msg_flags() == 1 {
                            match parse_descriptors(response.get_format_data()) {
                                Ok(entries) => {
                                    s.snapshot.entry_count = entries.len() as u32;
                                    s.remote_entries = entries;
                                    s.snapshot.state = 3;
                                    s.snapshot.diagnostic_code = 0;
                                }
                                Err(_) => {
                                    s.snapshot.state = 4;
                                    s.snapshot.diagnostic_code = 12;
                                }
                            }
                        } else {
                            s.snapshot.state = 5;
                            s.snapshot.diagnostic_code = 13;
                        }
                    } else {
                        Self::request_descriptor(&mut s)?;
                    }
                }
                Some(Cliprdr_oneof_union::file_contents_request(request)) => {
                    Self::serve_contents(&mut s, request)?
                }
                Some(Cliprdr_oneof_union::file_contents_response(response)) => {
                    let revision = s.snapshot.revision;
                    if let Some(pending) = s.pending.get_mut(&response.get_stream_id()) {
                        if pending.result.is_none() {
                            pending.result = Some(if pending.revision != revision {
                                Err(err(io::ErrorKind::Interrupted, "clipboard source replaced"))
                            } else if response.get_msg_flags() != 1
                                || response.get_requested_data().len() != pending.expected
                            {
                                Err(err(
                                    io::ErrorKind::InvalidData,
                                    "clipboard range response mismatch",
                                ))
                            } else {
                                Ok(response.get_requested_data().to_vec())
                            });
                        }
                    }
                }
                _ => {} // Files is an audit record, never a descriptor or received file.
            }
            Ok(())
        })();
        if result.is_err() {
            Self::invalidate(&mut s, 10, false);
        }
        Self::poll(&mut s);
        drop(s);
        self.wake.notify_all();
    }
    fn request_data(
        &self,
        revision: u64,
        index: usize,
        flags: i32,
        offset: u64,
        length: usize,
        job: &TransferJob,
    ) -> io::Result<Vec<u8>> {
        job.check()?;
        let stream = NEXT_STREAM.fetch_add(1, Ordering::Relaxed);
        if stream == 0 || stream > i32::MAX as u64 {
            return Err(err(io::ErrorKind::Other, "clipboard stream id exhausted"));
        }
        let stream = stream as i32;
        let gate = Arc::new(AtomicBool::new(true));
        let mut s = self
            .state
            .lock()
            .map_err(|_| err(io::ErrorKind::Other, "clipboard lock"))?;
        if !Self::allowed(&s)
            || !s.enabled
            || s.inbound_blocked
            || s.snapshot.state != 3
            || s.snapshot.revision != revision
            || index >= s.remote_entries.len()
            || s.pending.len() >= 4
        {
            return Err(err(
                io::ErrorKind::Interrupted,
                "clipboard source unavailable",
            ));
        }
        let mut request = CliprdrFileContentsRequest::new();
        request.set_stream_id(stream);
        request.set_list_index(index as i32);
        request.set_dw_flags(flags);
        request.set_n_position_low(offset as u32 as i32);
        request.set_n_position_high((offset >> 32) as u32 as i32);
        request.set_cb_requested(length as i32);
        request.set_have_clip_data_id(false);
        Self::queue(
            &mut s,
            with_clip(Cliprdr_oneof_union::file_contents_request(request)),
            gate.clone(),
            crate::control_inbox::PERMISSION_CLIPBOARD | crate::control_inbox::PERMISSION_FILE,
        )?;
        s.pending.insert(
            stream,
            PendingResponse {
                revision,
                expected: length,
                result: None,
                gate: gate.clone(),
            },
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        let result = loop {
            if let Err(error) = job.check() {
                break Err(error);
            }
            if !Self::allowed(&s) || !s.enabled || s.snapshot.revision != revision {
                break Err(err(io::ErrorKind::Interrupted, "clipboard source replaced"));
            }
            if let Some(result) = s.pending.get_mut(&stream).and_then(|v| v.result.take()) {
                break result;
            }
            if Instant::now() >= deadline {
                break Err(err(io::ErrorKind::TimedOut, "clipboard contents deadline"));
            }
            s = match self.wake.wait_timeout(s, Duration::from_millis(100)) {
                Ok((next, _)) => next,
                Err(_) => {
                    gate.store(false, Ordering::Release);
                    return Err(err(io::ErrorKind::Other, "clipboard response lock"));
                }
            };
        };
        gate.store(false, Ordering::Release);
        s.pending.remove(&stream);
        result
    }
    pub fn receive_into(
        &self,
        revision: u64,
        index: usize,
        mut sink: DownloadSink,
        job: &TransferJob,
    ) -> io::Result<()> {
        let entries = self
            .entries(revision)
            .ok_or_else(|| err(io::ErrorKind::Interrupted, "clipboard source replaced"))?;
        let entry = entries
            .get(index)
            .ok_or_else(|| err(io::ErrorKind::InvalidInput, "clipboard file index"))?;
        if entry.is_directory || sink.expected_size != entry.size || sink.modified != entry.modified
        {
            return Err(err(
                io::ErrorKind::InvalidInput,
                "clipboard receive metadata mismatch",
            ));
        }
        let size = self.request_data(revision, index, 1, 0, 8, job)?;
        if u64::from_le_bytes(
            size.as_slice()
                .try_into()
                .map_err(|_| err(io::ErrorKind::InvalidData, "clipboard size response"))?,
        ) != entry.size
        {
            return Err(err(
                io::ErrorKind::InvalidData,
                "clipboard source size changed",
            ));
        }
        let mut offset = 0u64;
        while offset < entry.size {
            let length = (entry.size - offset).min(64 * 1024) as usize;
            let bytes = self.request_data(revision, index, 2, offset, length, job)?;
            sink.write_block(&bytes, false, job)?;
            offset += bytes.len() as u64;
        }
        if self.entries(revision).is_none() {
            return Err(err(io::ErrorKind::Interrupted, "clipboard source replaced"));
        }
        sink.complete(job)?;
        if self.entries(revision).is_none() {
            return Err(err(io::ErrorKind::Interrupted, "clipboard source replaced"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control_inbox::ControlInbox;
    use std::fs::{File, OpenOptions};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::thread;
    fn enabled() -> Arc<ControlInbox> {
        let controls = Arc::new(ControlInbox::default());
        controls.file_clipboard.bind_controls(&controls);
        let mut info = PeerInfo::new();
        info.set_platform("Windows".into());
        info.set_version("1.4.7".into());
        info.set_platform_additions("{\"has_file_clipboard\":true}".into());
        controls.file_clipboard.update_peer(&info);
        assert!(controls.file_clipboard.configure(true));
        let outputs = flush(&controls.file_clipboard);
        assert_eq!(outputs.len(), 2);
        assert!(
            outputs[0]
                .get_misc()
                .get_option()
                .get_enable_file_transfer()
                == OptionMessage_BoolOption::Yes
        );
        controls
    }
    fn flush(engine: &FileClipboard) -> Vec<Message> {
        let mut messages = Vec::new();
        loop {
            let outputs = engine.take_outputs();
            if outputs.is_empty() {
                break;
            }
            for out in outputs {
                if out.receipt.begin_write() {
                    messages.push(protobuf::parse_from_bytes(&out.bytes).unwrap());
                    out.receipt.written();
                }
            }
        }
        messages
    }
    fn temporary_file() -> File {
        let path = std::env::temp_dir().join(format!(
            "rd-cliprdr-{}-{}",
            std::process::id(),
            NEXT_PUBLICATION.fetch_add(1, Ordering::Relaxed)
        ));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        std::fs::remove_file(path).unwrap();
        file
    }
    fn source(name: &str, bytes: &[u8]) -> ClipboardFileSource {
        let mut file = temporary_file();
        file.write_all(bytes).unwrap();
        let source = UploadSource::file(file).unwrap();
        ClipboardFileSource {
            entry: ClipboardFileEntry {
                name: name.into(),
                is_directory: false,
                size: source.size(),
                modified: source.modified(),
            },
            source: Some(source),
        }
    }
    fn list(format: i32) -> Cliprdr {
        let mut list = CliprdrServerFormatList::new();
        for (id, name) in [(format, DESCRIPTOR_NAME), (CONTENTS_FORMAT, CONTENTS_NAME)] {
            let mut f = CliprdrFormat::new();
            f.set_id(id);
            f.set_format(name.into());
            list.mut_formats().push(f);
        }
        let mut clip = Cliprdr::new();
        clip.set_format_list(list);
        clip
    }
    fn descriptor_response(entries: &[ClipboardFileEntry]) -> Cliprdr {
        let mut response = CliprdrServerFormatDataResponse::new();
        response.set_msg_flags(1);
        response.set_format_data(build_descriptors(entries).unwrap());
        let mut clip = Cliprdr::new();
        clip.set_format_data_response(response);
        clip
    }
    fn descriptor_request(format: i32) -> Cliprdr {
        let mut request = CliprdrServerFormatDataRequest::new();
        request.set_requested_format_id(format);
        let mut clip = Cliprdr::new();
        clip.set_format_data_request(request);
        clip
    }
    fn ack() -> Cliprdr {
        let mut response = CliprdrServerFormatListResponse::new();
        response.set_msg_flags(1);
        let mut clip = Cliprdr::new();
        clip.set_format_list_response(response);
        clip
    }
    fn content_request(index: i32, offset: u64, count: i32, clip_id: Option<i32>) -> Cliprdr {
        let mut request = CliprdrFileContentsRequest::new();
        request.set_stream_id(91);
        request.set_list_index(index);
        request.set_dw_flags(2);
        request.set_n_position_low(offset as u32 as i32);
        request.set_n_position_high((offset >> 32) as i32);
        request.set_cb_requested(count);
        request.set_have_clip_data_id(clip_id.is_some());
        request.set_clip_data_id(clip_id.unwrap_or(0));
        let mut clip = Cliprdr::new();
        clip.set_file_contents_request(request);
        clip
    }
    #[test]
    fn cliprdr_descriptor_layout_handles_files_folders_empty_unicode_and_rejects_unsafe_data() {
        let entries = vec![
            ClipboardFileEntry {
                name: "folder".into(),
                is_directory: true,
                size: 0,
                modified: 1_700_000_123,
            },
            ClipboardFileEntry {
                name: "folder/测试😀.txt".into(),
                is_directory: false,
                size: 0,
                modified: 1_700_000_124,
            },
            ClipboardFileEntry {
                name: "big.bin".into(),
                is_directory: false,
                size: MAX_FILE_SIZE,
                modified: 1_700_000_125,
            },
        ];
        let bytes = build_descriptors(&entries).unwrap();
        assert_eq!(bytes.len(), 4 + 3 * 592);
        let decoded = parse_descriptors(&bytes).unwrap();
        assert_eq!(decoded[1].name, entries[1].name);
        assert_eq!(decoded[2].size, MAX_FILE_SIZE);
        assert!(decoded[0].is_directory);
        for value in [
            "../escape",
            "/absolute",
            "C:\\host",
            "a//b",
            "CON.txt",
            "one.",
            "a\\..\\b",
        ] {
            assert!(normalized_name(value).is_err(), "{value}");
        }
        let mut malformed = bytes.clone();
        malformed.truncate(malformed.len() - 1);
        assert!(parse_descriptors(&malformed).is_err());
        let mut malformed = bytes.clone();
        malformed[4 + 36..4 + 40].copy_from_slice(&0x400u32.to_le_bytes());
        assert!(parse_descriptors(&malformed).is_err());
        let mut malformed = bytes.clone();
        malformed[4 + 72..4 + 592].fill(0x41);
        assert!(parse_descriptors(&malformed).is_err());
        let mut collisions = vec![entries[2].clone(), entries[2].clone()];
        collisions[0].name = "A.bin".into();
        collisions[1].name = "a.BIN".into();
        assert!(build_descriptors(&collisions).is_err());
        assert_eq!(std::mem::size_of::<FileClipboardSnapshot>(), 32);
        assert_eq!(std::mem::size_of::<FileClipboardPublication>(), 32);
    }
    #[test]
    fn cliprdr_capability_requires_the_authenticated_top_level_boolean_and_supported_platform() {
        assert!(json_file_capability(
            "{\"other\":[1,{\"a\":false}],\"has_file_clipboard\":true}"
        ));
        for json in [
            "{\"other\":{\"has_file_clipboard\":true}}",
            "{\"has_file_clipboard\":false}",
            "{\"other\":\"has_file_clipboard:true\"}",
            "{\"has_file_clipboard\":true,\"has_file_clipboard\":false}",
            "{\"has_file_clipboard\":true}garbage",
            "{\"has_file_clipboard\":\"true\"}",
        ] {
            assert!(!json_file_capability(json), "{json}");
        }
        let controls = Arc::new(ControlInbox::default());
        controls.file_clipboard.bind_controls(&controls);
        assert!(controls.file_clipboard.configure(true));
        assert_eq!(controls.file_clipboard.snapshot().enabled, 0);
        let mut peer = PeerInfo::new();
        peer.set_platform("Mac OS".into());
        peer.set_version("1.3.8".into());
        peer.set_platform_additions("{\"has_file_clipboard\":true}".into());
        controls.file_clipboard.update_peer(&peer);
        assert_eq!(controls.file_clipboard.snapshot().capable, 0);
        peer.set_version("1.3.9".into());
        controls.file_clipboard.update_peer(&peer);
        assert_eq!(controls.file_clipboard.snapshot().enabled, 1);
    }
    #[test]
    fn cliprdr_source_sequence_is_shared_and_stale_descriptor_responses_are_drained() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        engine.observe_text(Some(b"first"));
        let initial = controls.remote_clipboard.lock().unwrap().revision;
        engine.handle_message(&list(50100));
        let first = engine.snapshot().revision;
        assert!(first > initial);
        assert!(controls.remote_clipboard.lock().unwrap().files);
        flush(engine);
        engine.handle_message(&list(50101));
        let second = engine.snapshot().revision;
        assert!(second > first);
        let old = source("old.bin", b"old").entry;
        engine.handle_message(&descriptor_response(&[old]));
        assert_eq!(engine.snapshot().state, 2);
        let messages = flush(engine);
        assert!(messages.iter().any(|v| v
            .get_cliprdr()
            .get_format_data_request()
            .get_requested_format_id()
            == 50101));
        let new = source("new.bin", b"new").entry;
        engine.handle_message(&descriptor_response(&[new]));
        assert_eq!(engine.entries(second).unwrap()[0].name, "new.bin");
        assert!(engine.entries(first).is_none());
        engine.observe_text(Some(b"first"));
        assert!(engine.snapshot().revision > second);
        assert!(!controls.remote_clipboard.lock().unwrap().files);
        let repeated = engine.snapshot().revision;
        engine.observe_text(Some(b"first"));
        assert_eq!(engine.snapshot().revision, repeated + 1);
        engine.observe_text(None);
        assert!(controls.remote_clipboard.lock().unwrap().unsupported);
        let before = engine.snapshot().revision;
        let mut audit = Cliprdr::new();
        audit.set_files(CliprdrFiles::new());
        engine.handle_message(&audit);
        assert_eq!(engine.snapshot().revision, before);
    }
    #[test]
    fn cliprdr_unix_publication_waits_for_actual_descriptor_write_and_pins_untagged_source() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let id = engine
            .publish(vec![source("first.bin", b"first-data")])
            .unwrap();
        let format = flush(engine)[0]
            .get_cliprdr()
            .get_format_list()
            .get_formats()[0]
            .get_id();
        assert_eq!(engine.publication(id).state, 1);
        engine.handle_message(&descriptor_request(format));
        let pending = engine.take_outputs();
        assert_eq!(pending.len(), 1);
        assert_eq!(engine.publication(id).state, 1);
        let out = pending.into_iter().next().unwrap();
        assert!(out.receipt.begin_write());
        out.receipt.written();
        drop(out);
        assert_eq!(engine.publication(id).state, 2);
        engine.handle_message(&content_request(0, 2, 5, None));
        let messages = flush(engine);
        assert_eq!(
            messages[0]
                .get_cliprdr()
                .get_file_contents_response()
                .get_requested_data(),
            b"rst-d"
        );
        assert_eq!(engine.publication(id).requested_bytes, 5);
        assert!(engine.publish(vec![source("new.bin", b"new")]).is_err());
        assert!(engine.revoke_publication(id));
        flush(engine);
        engine.handle_message(&ack());
        assert_eq!(engine.publication(id).drained, 1);
        engine.handle_message(&content_request(0, 0, 3, None));
        assert_eq!(
            flush(engine)[0]
                .get_cliprdr()
                .get_file_contents_response()
                .get_msg_flags(),
            2
        );
        assert!(
            engine.publish(vec![source("new.bin", b"new")]).is_err(),
            "untagged old indices require reconnect, never substitute a new FD"
        );
    }
    #[test]
    fn cliprdr_tagged_revocation_retires_ids_and_failure_cancel_permission_and_disconnect_drain() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let id = engine.publish(vec![source("one.bin", b"one")]).unwrap();
        let format = flush(engine)[0]
            .get_cliprdr()
            .get_format_list()
            .get_formats()[0]
            .get_id();
        engine.handle_message(&ack());
        engine.handle_message(&descriptor_request(format));
        flush(engine);
        engine.handle_message(&content_request(0, 0, 3, Some(10)));
        flush(engine);
        assert!(engine.revoke_publication(id));
        flush(engine);
        engine.handle_message(&ack());
        assert_eq!(engine.publication(id).state, 5);
        assert!(engine.publish(vec![source("two.bin", b"two")]).is_err());
        engine.handle_message(&content_request(0, 0, 3, Some(10)));
        assert_eq!(
            flush(engine)[0]
                .get_cliprdr()
                .get_file_contents_response()
                .get_msg_flags(),
            2
        );
        // Only a new carrier resets outbound admission; permissions still revoke
        // queued source writes on that new carrier.
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let next = engine.publish(vec![source("two.bin", b"two")]).unwrap();
        let format = flush(engine)[0]
            .get_cliprdr()
            .get_format_list()
            .get_formats()[0]
            .get_id();
        engine.handle_message(&ack());
        engine.handle_message(&descriptor_request(format));
        flush(engine);
        engine.handle_message(&content_request(0, 0, 3, Some(11)));
        let queued = engine.take_outputs();
        controls.update_permission(crate::control_inbox::PERMISSION_FILE, false);
        for output in queued {
            assert!(!output.receipt.begin_write());
        }
        assert_eq!(engine.publication(next).state, 6);
        assert_eq!(engine.publication(next).drained, 1);
        assert_eq!(engine.snapshot().enabled, 0);
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let id = engine.publish(vec![source("one.bin", b"one")]).unwrap();
        let queued = engine.take_outputs();
        controls.request_shutdown();
        for output in queued {
            assert!(!output.receipt.begin_write());
        }
        assert_eq!(engine.publication(id).state, 6);
        assert_eq!(engine.publication(id).drained, 1);
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let id = engine.publish(vec![source("one.bin", b"one")]).unwrap();
        drop(engine.take_outputs());
        engine
            .state
            .lock()
            .unwrap()
            .offers
            .get_mut(&id)
            .unwrap()
            .published = Instant::now() - Duration::from_secs(11);
        assert_eq!(engine.publication(id).state, 6);
        assert_eq!(engine.publication(id).drained, 1);
    }
    #[test]
    fn cliprdr_descriptor_timeout_never_relabels_a_late_response_as_a_new_source() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        engine.handle_message(&list(50001));
        flush(engine);
        engine
            .state
            .lock()
            .unwrap()
            .descriptor_request
            .as_mut()
            .unwrap()
            .started = Instant::now() - Duration::from_secs(11);
        assert_eq!(engine.snapshot().state, 5);
        engine.handle_message(&list(50002));
        engine.handle_message(&descriptor_response(&[source("late.bin", b"late").entry]));
        assert!(engine.entries(engine.snapshot().revision).is_none());
        assert!(flush(engine).is_empty());
    }
    #[test]
    fn cliprdr_receive_wire_requests_size_and_ranges_and_fsyncs_only_complete_file() {
        use crate::protocol::wire;
        let controls = enabled();
        let engine = controls.file_clipboard.clone();
        let content = vec![0x5au8; 200_000];
        let peer_content = content.clone();
        let entry = ClipboardFileEntry {
            name: "remote.bin".into(),
            is_directory: false,
            size: content.len() as u64,
            modified: 1_700_000_123,
        };
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let peer = thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(4)))
                .unwrap();
            wire::write_frame(&mut socket, &message(list(51001)).write_to_bytes().unwrap())
                .unwrap();
            let mut ranges = 0;
            let mut size_requests = 0;
            while let Ok(bytes) = wire::read_frame(&mut socket) {
                let request: Message = protobuf::parse_from_bytes(&bytes).unwrap();
                match request.get_cliprdr().union.as_ref() {
                    Some(Cliprdr_oneof_union::format_list_response(response)) => {
                        assert_eq!(response.get_msg_flags(), 1)
                    }
                    Some(Cliprdr_oneof_union::format_data_request(request)) => {
                        assert_eq!(request.get_requested_format_id(), 51001);
                        wire::write_frame(
                            &mut socket,
                            &message(descriptor_response(&[entry.clone()]))
                                .write_to_bytes()
                                .unwrap(),
                        )
                        .unwrap();
                    }
                    Some(Cliprdr_oneof_union::file_contents_request(request)) => {
                        assert_eq!(request.get_list_index(), 0);
                        assert!(!request.get_have_clip_data_id());
                        let data = if request.get_dw_flags() == 1 {
                            size_requests += 1;
                            (peer_content.len() as u64).to_le_bytes().to_vec()
                        } else {
                            ranges += 1;
                            let offset = ((request.get_n_position_high() as u32 as u64) << 32)
                                | request.get_n_position_low() as u32 as u64;
                            let n = request.get_cb_requested() as usize;
                            assert!(n > 0 && n <= 65536);
                            peer_content[offset as usize..offset as usize + n].to_vec()
                        };
                        let mut response = CliprdrFileContentsResponse::new();
                        response.set_stream_id(request.get_stream_id());
                        response.set_msg_flags(1);
                        response.set_requested_data(data);
                        wire::write_frame(
                            &mut socket,
                            &with_clip(Cliprdr_oneof_union::file_contents_response(response))
                                .write_to_bytes()
                                .unwrap(),
                        )
                        .unwrap();
                    }
                    _ => panic!("unexpected file clipboard wire message"),
                }
            }
            assert_eq!(size_requests, 1);
            assert_eq!(ranges, 4);
        });
        let stop = Arc::new(AtomicBool::new(false));
        let driver_stop = stop.clone();
        let driver_engine = engine.clone();
        let driver = thread::spawn(move || {
            let socket = TcpStream::connect(address).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_millis(10)))
                .unwrap();
            let mut channel = crate::crypto_channel::CryptoChannel::new_plain(socket);
            channel.start_streaming_writer().unwrap();
            while !driver_stop.load(Ordering::Acquire) {
                for output in driver_engine.take_outputs() {
                    channel
                        .send_with_publication(&output.bytes, output.receipt)
                        .unwrap();
                }
                match channel.recv() {
                    Ok(bytes) => {
                        let msg: Message = protobuf::parse_from_bytes(&bytes).unwrap();
                        driver_engine.handle_message(msg.get_cliprdr());
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                        ) => {}
                    Err(error) => panic!("file clipboard wire: {error:?}"),
                }
            }
        });
        let deadline = Instant::now() + Duration::from_secs(4);
        while engine.snapshot().state != 3 {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(1));
        }
        let revision = engine.snapshot().revision;
        let mut destination = temporary_file();
        let sink = DownloadSink::new(
            destination.try_clone().unwrap(),
            content.len() as u64,
            1_700_000_123,
        )
        .unwrap();
        let job = crate::file_transfer::TransferRegistry::default()
            .insert(44, content.len() as u64)
            .unwrap();
        job.bind_permissions(controls.clone());
        let result = engine.receive_into(revision, 0, sink, &job);
        job.finish(result);
        stop.store(true, Ordering::Release);
        driver.join().unwrap();
        peer.join().unwrap();
        let status = job.status.lock().unwrap();
        assert_eq!(status.0.state, 6, "{}", status.1);
        assert_eq!(status.0.transferred_bytes, content.len() as u64);
        let mut bytes = Vec::new();
        destination.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, content);
        assert_eq!(
            destination
                .metadata()
                .unwrap()
                .modified()
                .unwrap()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            1_700_000_123
        );
    }
    #[test]
    fn cliprdr_receive_source_change_and_cancel_retire_stream_ids_without_writing_late_data() {
        for cancel in [false, true] {
            let controls = enabled();
            let engine = controls.file_clipboard.clone();
            engine.handle_message(&list(52001));
            flush(&engine);
            engine.handle_message(&descriptor_response(&[
                source("remote.bin", b"remote").entry
            ]));
            let revision = engine.snapshot().revision;
            let job = crate::file_transfer::TransferRegistry::default()
                .insert(55, 6)
                .unwrap();
            job.bind_permissions(controls.clone());
            let worker_job = job.clone();
            let worker_engine = engine.clone();
            let worker = thread::spawn(move || {
                worker_engine.request_data(revision, 0, 1, 0, 8, &worker_job)
            });
            let deadline = Instant::now() + Duration::from_secs(2);
            let stream = loop {
                if let Some(id) = engine.state.lock().unwrap().pending.keys().next().copied() {
                    break id;
                }
                assert!(Instant::now() < deadline);
                thread::sleep(Duration::from_millis(1));
            };
            if cancel {
                job.cancel();
            } else {
                engine.observe_text(Some(b"new clipboard"));
            }
            assert_eq!(
                worker.join().unwrap().unwrap_err().kind(),
                io::ErrorKind::Interrupted
            );
            let mut late = CliprdrFileContentsResponse::new();
            late.set_stream_id(stream);
            late.set_msg_flags(1);
            late.set_requested_data(6u64.to_le_bytes().to_vec());
            engine.handle_message(
                with_clip(Cliprdr_oneof_union::file_contents_response(late)).get_cliprdr(),
            );
            assert!(engine.state.lock().unwrap().pending.is_empty());
            for output in engine.take_outputs() {
                assert!(!output.receipt.begin_write());
            }
            assert_eq!(job.status.lock().unwrap().0.transferred_bytes, 0);
        }
    }
    #[test]
    fn cliprdr_late_unseen_tag_after_revoke_cannot_read_a_successor_publication() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let first = engine.publish(vec![source("old.bin", b"old")]).unwrap();
        let format = flush(engine)[0]
            .get_cliprdr()
            .get_format_list()
            .get_formats()[0]
            .get_id();
        engine.handle_message(&ack());
        engine.handle_message(&descriptor_request(format));
        flush(engine);
        assert!(engine.revoke_publication(first));
        flush(engine);
        engine.handle_message(&ack());
        assert_eq!(engine.publication(first).state, 5);
        assert_eq!(engine.publication(first).drained, 1);
        assert!(engine.publish(vec![source("new.bin", b"NEW")]).is_err());
        engine.handle_message(&content_request(0, 0, 3, Some(123)));
        let messages = flush(engine);
        let response = messages[0].get_cliprdr().get_file_contents_response();
        assert_eq!(response.get_msg_flags(), 2);
        assert!(response.get_requested_data().is_empty());
        // A settings toggle cannot pretend to be a new authenticated carrier.
        assert!(engine.configure(false));
        assert!(engine.configure(true));
        flush(engine);
        assert!(engine
            .publish(vec![source("still-new.bin", b"NEW")])
            .is_err());
    }

    #[test]
    fn cliprdr_late_try_empty_does_not_replace_newer_remote_text() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        engine.handle_message(&list(50001));
        engine.observe_text(Some(b"new text"));
        let revision = controls.remote_clipboard.lock().unwrap().revision;
        let mut empty = Cliprdr::new();
        empty.set_try_empty(CliprdrTryEmpty::new());
        engine.handle_message(&empty);
        let current = controls.remote_clipboard.lock().unwrap();
        assert_eq!(current.revision, revision);
        assert_eq!(current.content, b"new text");
        drop(current);
        engine.handle_message(&list(50002));
        let revision = controls.remote_clipboard.lock().unwrap().revision;
        engine.handle_message(&empty);
        let current = controls.remote_clipboard.lock().unwrap();
        assert_eq!(current.revision, revision + 1);
        assert!(!current.files);
        assert!(current.content.is_empty());
    }

    #[test]
    fn cliprdr_revoke_retains_source_until_inflight_content_write_finishes() {
        let controls = enabled();
        let engine = &controls.file_clipboard;
        let id = engine.publish(vec![source("one.bin", b"one")]).unwrap();
        let format = flush(engine)[0]
            .get_cliprdr()
            .get_format_list()
            .get_formats()[0]
            .get_id();
        engine.handle_message(&ack());
        engine.handle_message(&descriptor_request(format));
        flush(engine);
        engine.handle_message(&content_request(0, 0, 3, Some(77)));
        let output = engine.take_outputs().pop().unwrap();
        assert!(output.receipt.begin_write());
        assert!(engine.revoke_publication(id));
        flush(engine);
        engine.handle_message(&ack());
        assert_eq!(engine.publication(id).drained, 0);
        assert_eq!(
            engine
                .state
                .lock()
                .unwrap()
                .offers
                .get(&id)
                .unwrap()
                .sources
                .len(),
            1
        );
        output.receipt.written();
        drop(output);
        assert_eq!(engine.publication(id).drained, 1);
        assert!(engine
            .state
            .lock()
            .unwrap()
            .offers
            .get(&id)
            .unwrap()
            .sources
            .is_empty());
    }
}
