//! Bounded file I/O and per-job state. Transport completion is separate from content verification.
use crate::RustDeskTransferStatus;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read};
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub(crate) enum UploadSource {
    Memory(Vec<u8>),
    File {
        file: File,
        size: u64,
        modified: u64,
        observed_modified: SystemTime,
    },
}
impl UploadSource {
    pub fn file(file: File) -> io::Result<Self> {
        use std::os::fd::AsRawFd;
        let metadata = file.metadata()?;
        let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
        if !metadata.is_file() || flags < 0 || flags & libc::O_ACCMODE == libc::O_WRONLY {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "upload requires a regular file",
            ));
        }
        if metadata.len() > (u32::MAX as u64 + 1) * 65536 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "upload exceeds wire block range",
            ));
        }
        let modified = metadata
            .modified()?
            .duration_since(UNIX_EPOCH)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid source timestamp"))?
            .as_secs();
        Ok(Self::File {
            file,
            size: metadata.len(),
            modified,
            observed_modified: metadata.modified()?,
        })
    }
    pub fn size(&self) -> u64 {
        match self {
            Self::Memory(data) => data.len() as u64,
            Self::File { size, .. } => *size,
        }
    }
    pub fn modified(&self) -> u64 {
        match self {
            Self::Memory(_) => SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            Self::File { modified, .. } => *modified,
        }
    }
    pub fn read_at(&self, offset: u64, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Memory(data) => (&data[(offset.min(data.len() as u64) as usize)..]).read(buffer),
            Self::File { file, .. } => file.read_at(buffer, offset),
        }
    }
    pub fn validate_unchanged(&self) -> io::Result<()> {
        if let Self::File {
            file,
            size,
            observed_modified,
            ..
        } = self
        {
            let metadata = file.metadata()?;
            if metadata.len() != *size || metadata.modified()? != *observed_modified {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "upload source changed",
                ));
            }
        }
        Ok(())
    }
}

pub(crate) struct TransferJob {
    pub status: Mutex<(RustDeskTransferStatus, String)>,
    cancelled: AtomicBool,
    remote_write_started: AtomicBool,
    epoch: Mutex<u64>,
    permissions: Mutex<Option<Arc<crate::control_inbox::ControlInbox>>>,
    started: Instant,
    last_progress: Mutex<Instant>,
    pub directory: Mutex<Option<RemoteDirectory>>,
    pub auth: Arc<crate::file_auth::FileAuthExchange>,
    pub result: Mutex<FileOperationResult>,
}
impl TransferJob {
    fn new(id: u64, size: u64) -> Self {
        Self {
            status: Mutex::new((
                RustDeskTransferStatus {
                    state: 2,
                    transfer_id: id,
                    transferred_bytes: 0,
                    total_bytes: size,
                    diagnostic_code: 0,
                },
                String::new(),
            )),
            cancelled: AtomicBool::new(false),
            remote_write_started: AtomicBool::new(false),
            epoch: Mutex::new(0),
            permissions: Mutex::new(None),
            started: Instant::now(),
            last_progress: Mutex::new(Instant::now()),
            directory: Mutex::new(None),
            auth: Arc::new(crate::file_auth::FileAuthExchange::new(id)),
            result: Mutex::new(FileOperationResult::default()),
        }
    }
    pub fn mark_remote_write_started(&self) {
        self.remote_write_started.store(true, Ordering::Release);
    }
    pub fn remote_write_started(&self) -> bool {
        self.remote_write_started.load(Ordering::Acquire)
    }
    pub fn bind_permissions(&self, controls: Arc<crate::control_inbox::ControlInbox>) {
        if let Ok(mut p) = self.permissions.lock() {
            *p = Some(controls);
        }
    }
    pub fn bind_epoch(&self, epoch: u64) {
        if let Ok(mut active) = self.epoch.lock() {
            *active = epoch;
            if self.cancelled.load(Ordering::SeqCst) {
                crate::cancel_connect_epoch(epoch);
            }
        }
    }
    pub fn cancel(&self) {
        self.auth.finish(false);
        // Serialize cancellation with the terminal status decision.
        let Ok(status) = self.status.lock() else {
            return;
        };
        if status.0.state != 2 {
            return;
        }
        self.cancelled.store(true, Ordering::SeqCst);
        if let Ok(epoch) = self.epoch.lock() {
            if *epoch != 0 {
                crate::cancel_connect_epoch(*epoch);
            }
        }
    }
    pub fn check(&self) -> io::Result<()> {
        if let Some(controls) = self
            .permissions
            .lock()
            .map_err(|_| io::Error::other("permission lock"))?
            .as_ref()
        {
            let p = controls.permission_snapshot();
            let file = crate::control_inbox::PERMISSION_FILE;
            if p.known_mask & file != 0 && p.enabled_mask & file == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "file permission revoked",
                ));
            }
        }
        let epoch = *self
            .epoch
            .lock()
            .map_err(|_| io::Error::other("epoch lock"))?;
        if self.cancelled.load(Ordering::SeqCst) || (epoch != 0 && crate::connect_cancelled(epoch))
        {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "file transfer cancelled",
            ));
        }
        if self.started.elapsed() > Duration::from_secs(24 * 60 * 60)
            || self
                .last_progress
                .lock()
                .map_err(|_| io::Error::other("progress lock"))?
                .elapsed()
                > Duration::from_secs(120)
        {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "file transfer deadline",
            ));
        }
        Ok(())
    }
    pub fn progress(&self, bytes: u64) {
        if let Ok(mut status) = self.status.lock() {
            if status.0.state == 2 {
                status.0.transferred_bytes = bytes.min(status.0.total_bytes);
            }
        }
        if let Ok(mut last) = self.last_progress.lock() {
            *last = Instant::now();
        }
    }
    pub fn finish(&self, result: io::Result<()>) {
        self.auth.finish(false);
        if let Ok(mut status) = self.status.lock() {
            if status.0.state != 2 {
                return;
            }
            match result.and_then(|()| self.check()) {
                Ok(()) => status.0.state = 6, // operation complete (download fsynced); remote content unverified
                Err(error) => {
                    status.0.state = if error.kind() == io::ErrorKind::Interrupted {
                        5
                    } else {
                        4
                    };
                    status.0.diagnostic_code = 1;
                    status.1 = format!("file_transfer:{}", file_error_code(&error));
                }
            }
        }
        // Do not retain an expired epoch that could be cancelled after its reservation drops.
        if let Ok(mut epoch) = self.epoch.lock() {
            *epoch = 0;
        }
    }
}
/// Failure reasons the app explains to the user; any other error is reported by its kind.
pub(crate) const REPORTED_FILE_ERRORS: &[&str] = &[
    "peer_prelogin",
    "peer_file_service_unavailable",
    "remote_file_transfer_disabled",
    "remote_one_way_transfer",
    "remote_path_not_found",
    "remote_permission_denied",
    "remote_disk_full",
];

pub(crate) fn file_error_code(error: &io::Error) -> String {
    let text = error.to_string();
    if REPORTED_FILE_ERRORS.contains(&text.as_str()) {
        text
    } else {
        format!("{:?}", error.kind())
    }
}

#[derive(Default)]
pub(crate) struct TransferRegistry {
    jobs: BTreeMap<u64, Arc<TransferJob>>,
    latest: u64,
}
impl TransferRegistry {
    pub fn insert(&mut self, id: u64, size: u64) -> io::Result<Arc<TransferJob>> {
        if id == 0 || self.jobs.contains_key(&id) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "transfer id already used",
            ));
        }
        if self.jobs.len() >= 256 {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "release completed transfer records first",
            ));
        }
        if self
            .jobs
            .values()
            .filter(|job| job.status.lock().map(|s| s.0.state == 2).unwrap_or(true))
            .count()
            >= 4
        {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "too many active transfers",
            ));
        }
        let job = Arc::new(TransferJob::new(id, size));
        self.jobs.insert(id, job.clone());
        self.latest = id;
        Ok(job)
    }
    pub fn get(&self, id: u64) -> Option<Arc<TransferJob>> {
        self.jobs
            .get(&if id == 0 { self.latest } else { id })
            .cloned()
    }
    pub fn release(&mut self, id: u64) -> bool {
        if self
            .jobs
            .get(&id)
            .is_some_and(|j| j.status.lock().map(|s| s.0.state != 2).unwrap_or(false))
        {
            self.jobs.remove(&id);
            true
        } else {
            false
        }
    }
}

/// Pump only bounded blocks; offset is source position, progress is actual newly sent bytes.
pub(crate) fn pump_upload(
    source: &UploadSource,
    job: &TransferJob,
    mut send: impl FnMut(u32, &[u8]) -> io::Result<()>,
) -> io::Result<()> {
    let mut buffer = [0u8; 65536];
    let mut offset = 0u64;
    while offset < source.size() {
        job.check()?;
        let wanted = (source.size() - offset).min(buffer.len() as u64) as usize;
        let mut read = 0;
        while read < wanted {
            job.check()?;
            let count = source.read_at(offset + read as u64, &mut buffer[read..wanted])?;
            if count == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "upload source shortened",
                ));
            }
            read += count;
        }
        let block = u32::try_from(offset / 65536).map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidInput, "file exceeds wire block range")
        })?;
        send(block, &buffer[..read])?;
        offset += read as u64;
        job.progress(offset);
    }
    job.check()?;
    source.validate_unchanged()
}

#[derive(Clone)]
pub(crate) struct RemoteFileEntry {
    pub name: String,
    pub entry_type: u32,
    pub size: u64,
    pub modified: u64,
}

pub(crate) struct DownloadSink {
    file: File,
    pub expected_size: u64,
    pub modified: u64,
    written: u64,
}
impl DownloadSink {
    pub fn new(file: File, expected_size: u64, modified: u64) -> io::Result<Self> {
        use std::os::fd::AsRawFd;
        let metadata = file.metadata()?;
        let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
        if !metadata.is_file()
            || metadata.len() != 0
            || flags < 0
            || flags & libc::O_APPEND != 0
            || flags & libc::O_ACCMODE == libc::O_RDONLY
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "download requires an empty writable stage fd",
            ));
        }
        if expected_size > (u32::MAX as u64 + 1) * 65536 || modified > i64::MAX as u64 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "remote metadata out of range",
            ));
        }
        Ok(Self {
            file,
            expected_size,
            modified,
            written: 0,
        })
    }
    pub fn write_block(
        &mut self,
        data: &[u8],
        compressed: bool,
        job: &TransferJob,
    ) -> io::Result<()> {
        const MAX_BLOCK: usize = 128 * 1024;
        job.check()?;
        if data.len() > MAX_BLOCK {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "download block exceeds limit",
            ));
        }
        let decoded;
        let bytes = if compressed {
            let mut decoder = zstd::stream::read::Decoder::new(data)?;
            decoder.window_log_max(19)?;
            let mut bounded = decoder.take((MAX_BLOCK + 1) as u64);
            let mut result = Vec::new();
            bounded.read_to_end(&mut result)?;
            if result.len() > MAX_BLOCK {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "download decompression exceeds limit",
                ));
            }
            decoded = result;
            decoded.as_slice()
        } else {
            data
        };
        if bytes.len() as u64 > self.expected_size.saturating_sub(self.written) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "download exceeds expected file size",
            ));
        }
        let mut offset = 0;
        while offset < bytes.len() {
            job.check()?;
            let n = self.file.write_at(&bytes[offset..], self.written)?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "download stage write returned zero",
                ));
            }
            offset += n;
            self.written += n as u64;
            job.progress(self.written);
        }
        Ok(())
    }
    pub fn complete(&self, job: &TransferJob) -> io::Result<()> {
        job.check()?;
        if self.written != self.expected_size || self.file.metadata()?.len() != self.expected_size {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "download size does not match metadata",
            ));
        }
        let modified = UNIX_EPOCH
            .checked_add(Duration::from_secs(self.modified))
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "remote timestamp out of range")
            })?;
        self.file
            .set_times(std::fs::FileTimes::new().set_modified(modified))?;
        self.file.sync_all()?;
        job.check()
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct FileOperationResult {
    pub operation_kind: u32,
    pub source_metadata_available: u32,
    pub source_size: u64,
    pub source_modified_time: u64,
    pub remote_operation_acknowledged: u32,
}

pub(crate) enum FileOperation {
    Upload {
        source: UploadSource,
        overwrite: bool,
    },
    List {
        include_hidden: bool,
    },
    /// Every file below a folder (relative names), from the peer's own recursive listing.
    Tree {
        include_hidden: bool,
    },
    CreateDirectory,
    /// A file, or a folder with everything in it.
    Remove {
        directory: bool,
    },
    Rename {
        new_name: String,
    },
    Download(DownloadSink),
}
impl FileOperation {
    pub fn size(&self) -> u64 {
        match self {
            Self::Upload { source, .. } => source.size(),
            Self::Download(sink) => sink.expected_size,
            _ => 0,
        }
    }

    /// The `operation_kind` reported in FileOperationResult.
    pub fn kind_code(&self) -> u32 {
        match self {
            Self::Upload { .. } => 1,
            Self::List { .. } => 2,
            Self::Download(_) => 3,
            Self::CreateDirectory => 4,
            Self::Remove { .. } => 5,
            Self::Rename { .. } => 6,
            Self::Tree { .. } => 7,
        }
    }
}

#[derive(Clone)]
pub(crate) struct RemoteDirectory {
    pub path: String,
    pub entries: Vec<RemoteFileEntry>,
}

#[cfg(test)]
mod download_tests {
    use super::*;
    use std::io::Write;
    fn stage() -> File {
        let path = std::env::temp_dir().join(format!(
            "rd-stage-{}-{}.bin",
            std::process::id(),
            crate::safe_diagnostics::sensitive_id(&format!("{:?}", Instant::now()))
        ));
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        std::fs::remove_file(path).unwrap();
        file
    }
    #[test]
    fn file_transfer_download_never_truncates_existing_content() {
        let mut file = stage();
        file.write_all(b"keep").unwrap();
        assert!(DownloadSink::new(file.try_clone().unwrap(), 1, 1).is_err());
        let mut bytes = [0; 4];
        file.read_exact_at(&mut bytes, 0).unwrap();
        assert_eq!(&bytes, b"keep");
    }
    #[test]
    fn file_transfer_download_decompression_and_size_are_bounded() {
        let file = stage();
        let mut sink = DownloadSink::new(file.try_clone().unwrap(), 10, 1).unwrap();
        let job = TransferJob::new(1, 10);
        let encoded = zstd::bulk::compress(&vec![4; 131073], 1).unwrap();
        assert!(sink.write_block(&encoded, true, &job).is_err());
        assert_eq!(file.metadata().unwrap().len(), 0);
        assert!(sink.write_block(&vec![4; 11], false, &job).is_err());
        assert_eq!(file.metadata().unwrap().len(), 0);
        assert!(sink.write_block(b"invalid-zstd", true, &job).is_err());
    }
    #[test]
    fn file_transfer_download_short_done_fails_and_empty_file_finishes() {
        let sink = DownloadSink::new(stage(), 10, 1).unwrap();
        let job = TransferJob::new(1, 10);
        assert_eq!(
            sink.complete(&job).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
        let file = stage();
        let sink = DownloadSink::new(file.try_clone().unwrap(), 0, 1_700_000_123).unwrap();
        sink.complete(&TransferJob::new(2, 0)).unwrap();
        assert_eq!(
            file.metadata()
                .unwrap()
                .modified()
                .unwrap()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            1_700_000_123
        );
    }
    #[test]
    fn file_transfer_download_cancel_preserves_partial_bytes_and_stops_writes() {
        let file = stage();
        let mut sink = DownloadSink::new(file.try_clone().unwrap(), 6, 1).unwrap();
        let job = TransferJob::new(1, 6);
        sink.write_block(b"abc", false, &job).unwrap();
        job.cancel();
        assert_eq!(
            sink.write_block(b"def", false, &job).unwrap_err().kind(),
            io::ErrorKind::Interrupted
        );
        assert_eq!(file.metadata().unwrap().len(), 3);
        assert_eq!(job.status.lock().unwrap().0.transferred_bytes, 3);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_worker_cannot_replace_latest_job() {
        let mut r = TransferRegistry::default();
        let a = r.insert(1, 10).unwrap();
        let b = r.insert(2, 20).unwrap();
        b.progress(20);
        b.finish(Ok(()));
        a.finish(Err(io::Error::other("late")));
        assert_eq!(r.get(0).unwrap().status.lock().unwrap().0.transfer_id, 2);
        assert_eq!(r.get(2).unwrap().status.lock().unwrap().0.state, 6);
        assert!(r.insert(2, 5).is_err());
    }
    #[test]
    fn pump_reports_written_blocks_and_cancels_between_blocks() {
        let source = UploadSource::Memory(vec![9; 200_000]);
        let job = TransferJob::new(1, source.size());
        let mut sent = 0;
        let error = pump_upload(&source, &job, |_, bytes| {
            sent += bytes.len();
            job.cancel();
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert_eq!(sent, 65536);
        assert_eq!(job.status.lock().unwrap().0.transferred_bytes, 65536);
    }
    #[test]
    fn empty_file_completes_without_data_block() {
        let source = UploadSource::Memory(Vec::new());
        let job = TransferJob::new(1, 0);
        pump_upload(&source, &job, |_, _| panic!("no blocks")).unwrap();
        job.finish(Ok(()));
        assert_eq!(job.status.lock().unwrap().0.state, 6);
    }
    #[test]
    fn failed_write_does_not_advance_progress() {
        let source = UploadSource::Memory(vec![1; 4]);
        let job = TransferJob::new(1, 4);
        assert!(pump_upload(&source, &job, |_, _| Err(io::Error::other("write"))).is_err());
        assert_eq!(job.status.lock().unwrap().0.transferred_bytes, 0);
    }
    #[test]
    fn release_requires_terminal_and_is_idempotent() {
        let mut r = TransferRegistry::default();
        let a = r.insert(1, 1).unwrap();
        assert!(!r.release(1));
        a.finish(Ok(()));
        assert!(r.release(1));
        assert!(!r.release(1));
    }
    #[test]
    fn file_transfer_fd_preserves_offset_metadata_and_detects_mutation() {
        use std::io::{Seek, SeekFrom, Write};
        let path = std::env::temp_dir().join(format!(
            "rd-upload-{}-{}.bin",
            std::process::id(),
            crate::safe_diagnostics::sensitive_id(&format!("{:?}", Instant::now()))
        ));
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)
            .unwrap();
        std::fs::remove_file(&path).unwrap();
        file.write_all(&vec![7; 150_000]).unwrap();
        file.seek(SeekFrom::Start(19)).unwrap();
        let source = UploadSource::file(file.try_clone().unwrap()).unwrap();
        assert!(source.modified() < 10_000_000_000);
        let job = TransferJob::new(1, source.size());
        let mut blocks = Vec::new();
        pump_upload(&source, &job, |i, data| {
            blocks.push((i, data.len()));
            assert!(data.iter().all(|b| *b == 7));
            Ok(())
        })
        .unwrap();
        assert_eq!(blocks, vec![(0, 65536), (1, 65536), (2, 18928)]);
        assert_eq!(file.stream_position().unwrap(), 19);
        file.set_len(4_294_967_300).unwrap();
        assert!(source.validate_unchanged().is_err());
        assert_eq!(UploadSource::file(file).unwrap().size(), 4_294_967_300);
    }
    #[test]
    fn file_transfer_permission_revocation_stops_next_block() {
        let source = UploadSource::Memory(vec![0; 100_000]);
        let job = TransferJob::new(1, source.size());
        let controls = Arc::new(crate::control_inbox::ControlInbox::default());
        job.bind_permissions(controls.clone());
        let error = pump_upload(&source, &job, |_, _| {
            controls.update_permission(crate::control_inbox::PERMISSION_FILE, false);
            Ok(())
        })
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(job.status.lock().unwrap().0.transferred_bytes, 65536);
    }
    #[test]
    fn file_transfer_many_tasks_converge_without_overwrite() {
        let mut registry = TransferRegistry::default();
        for n in 1..=100 {
            let a = registry.insert(n * 2, 1).unwrap();
            let b = registry.insert(n * 2 + 1, 2).unwrap();
            b.progress(2);
            b.finish(Ok(()));
            a.cancel();
            a.finish(a.check());
            assert_eq!(
                registry
                    .get(0)
                    .unwrap()
                    .status
                    .lock()
                    .unwrap()
                    .0
                    .transfer_id,
                n * 2 + 1
            );
            assert_eq!(a.status.lock().unwrap().0.state, 5);
            assert!(registry.release(n * 2));
            assert!(registry.release(n * 2 + 1));
        }
    }
    #[test]
    fn cancellation_before_terminal_commit_cannot_be_reported_complete() {
        let job = TransferJob::new(991234, 0);
        job.cancel();
        job.finish(Ok(()));
        assert_eq!(job.status.lock().unwrap().0.state, 5);
        job.finish(Ok(()));
        assert_eq!(job.status.lock().unwrap().0.state, 5);
        let completed = TransferJob::new(991235, 0);
        completed.finish(Ok(()));
        completed.cancel();
        assert_eq!(completed.status.lock().unwrap().0.state, 6);
    }
}
