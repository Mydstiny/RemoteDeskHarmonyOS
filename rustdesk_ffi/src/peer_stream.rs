//! Peer byte streams shared by direct TCP, relay TCP and RustDesk-compatible
//! UDP/KCP routes.
//!
//! The existing session pipeline is deliberately synchronous. KCP remains an
//! async protocol internally, so one dedicated current-thread Tokio runtime
//! owns each KCP endpoint and exposes bounded synchronous `Read`/`Write`
//! queues here. This keeps transport selection below encryption/framing while
//! preserving backpressure and deterministic shutdown.

use bytes::BytesMut;
use kcp_sys::{
    endpoint::KcpEndpoint,
    packet_def::{KcpPacket, KcpPacketHeader},
    stream::KcpStream,
};
use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc as std_mpsc, Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, watch, Notify};

const KCP_DATAGRAM_SIZE: usize = 1500;
const KCP_INBOUND_CAPACITY: usize = 32 * 1024 * 1024;
const KCP_OUTBOUND_CAPACITY: usize = 128;
const KCP_IO_CHUNK_SIZE: usize = 32 * 1024;
const KCP_QUEUE_WAIT_SLICE: Duration = Duration::from_millis(2);
const UDP_PUNCH_INITIAL_INTERVAL: Duration = Duration::from_millis(20);
const UDP_PUNCH_MAX_INTERVAL: Duration = Duration::from_millis(200);
const UDP_PUNCH_MAX_DURATION: Duration = Duration::from_secs(20);

#[derive(Clone, Debug)]
struct StoredError {
    kind: io::ErrorKind,
    message: String,
}

impl StoredError {
    fn from_io(error: &io::Error) -> Self {
        Self {
            kind: error.kind(),
            message: error.to_string(),
        }
    }

    fn to_io(&self) -> io::Error {
        io::Error::new(self.kind, self.message.clone())
    }
}

struct InboundState {
    chunks: VecDeque<Vec<u8>>,
    front_offset: usize,
    byte_len: usize,
    closed: bool,
    error: Option<StoredError>,
}

struct KcpShared {
    inbound: Mutex<InboundState>,
    readable: Condvar,
    space_available: Notify,
    closed: AtomicBool,
}

impl KcpShared {
    fn new() -> Self {
        Self {
            inbound: Mutex::new(InboundState {
                chunks: VecDeque::new(),
                front_offset: 0,
                byte_len: 0,
                closed: false,
                error: None,
            }),
            readable: Condvar::new(),
            space_available: Notify::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn finish(&self, error: Option<StoredError>) {
        self.closed.store(true, Ordering::SeqCst);
        if let Ok(mut state) = self.inbound.lock() {
            if state.error.is_none() {
                state.error = error;
            }
            state.closed = true;
        }
        self.readable.notify_all();
        self.space_available.notify_waiters();
    }

    fn current_error(&self) -> Option<StoredError> {
        self.inbound
            .lock()
            .ok()
            .and_then(|state| state.error.clone())
    }
}

struct KcpOwner {
    shared: Arc<KcpShared>,
    outbound: mpsc::Sender<Vec<u8>>,
    shutdown: watch::Sender<bool>,
    worker: Mutex<Option<JoinHandle<()>>>,
    local_address: SocketAddr,
    peer_address: SocketAddr,
}

impl KcpOwner {
    fn request_shutdown(&self) {
        self.shared.closed.store(true, Ordering::SeqCst);
        self.shutdown.send_replace(true);
        self.shared.finish(None);
    }
}

impl Drop for KcpOwner {
    fn drop(&mut self) {
        self.request_shutdown();
        if let Ok(mut worker) = self.worker.lock() {
            if let Some(handle) = worker.take() {
                let _ = handle.join();
            }
        }
    }
}

#[derive(Clone, Copy, Default)]
struct StreamTimeouts {
    read: Option<Duration>,
    write: Option<Duration>,
}

/// Synchronous view over an official `kcp-sys` endpoint.
pub struct KcpPeerStream {
    owner: Arc<KcpOwner>,
    timeouts: Mutex<StreamTimeouts>,
}

impl KcpPeerStream {
    pub fn connect(
        socket: UdpSocket,
        peer_address: SocketAddr,
        timeout: Duration,
        cancel_epoch: Option<u64>,
    ) -> io::Result<Self> {
        Self::connect_inner(
            socket,
            peer_address,
            timeout,
            cancel_epoch,
            Arc::new(AtomicBool::new(false)),
        )
    }

    pub(crate) fn connect_with_race_cancel(
        socket: UdpSocket,
        peer_address: SocketAddr,
        timeout: Duration,
        cancel_epoch: Option<u64>,
        race_cancel: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        Self::connect_inner(socket, peer_address, timeout, cancel_epoch, race_cancel)
    }

    fn connect_inner(
        socket: UdpSocket,
        peer_address: SocketAddr,
        timeout: Duration,
        cancel_epoch: Option<u64>,
        race_cancel: Arc<AtomicBool>,
    ) -> io::Result<Self> {
        validate_timeout(timeout)?;
        ensure_connect_active(cancel_epoch, &race_cancel)?;
        let local_before_connect = socket.local_addr()?;
        if local_before_connect.is_ipv4() != peer_address.is_ipv4() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "UDP/KCP socket family does not match peer candidate: local={} peer={}",
                    local_before_connect, peer_address
                ),
            ));
        }
        socket.connect(peer_address)?;
        socket.set_nonblocking(true)?;
        let local_address = socket.local_addr()?;

        let shared = Arc::new(KcpShared::new());
        let worker_shared = Arc::clone(&shared);
        let (outbound, outbound_rx) = mpsc::channel(KCP_OUTBOUND_CAPACITY);
        let (shutdown, shutdown_rx) = watch::channel(false);
        let worker_shutdown = shutdown.clone();
        let worker_race_cancel = Arc::clone(&race_cancel);
        let (ready_tx, ready_rx) = std_mpsc::sync_channel::<Result<(), StoredError>>(1);
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "KCP timeout overflow"))?;

        let worker = thread::Builder::new()
            .name("rustdesk-kcp-peer".to_string())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|error| {
                        io::Error::new(io::ErrorKind::Other, format!("create KCP runtime: {error}"))
                    });
                let result = runtime.and_then(|runtime| {
                    runtime.block_on(run_kcp_worker(
                        socket,
                        worker_shared.clone(),
                        outbound_rx,
                        shutdown_rx,
                        ready_tx.clone(),
                        deadline,
                        cancel_epoch,
                        worker_race_cancel,
                    ))
                });

                match result {
                    Ok(()) => worker_shared.finish(None),
                    Err(error) => {
                        let stored = StoredError::from_io(&error);
                        let _ = ready_tx.try_send(Err(stored.clone()));
                        worker_shared.finish(Some(stored));
                    }
                }
            })?;

        let ready_wait = timeout.saturating_add(Duration::from_millis(250));
        match ready_rx.recv_timeout(ready_wait) {
            Ok(Ok(())) => {
                if let Err(error) = ensure_connect_active(cancel_epoch, &race_cancel) {
                    worker_shutdown.send_replace(true);
                    let _ = worker.join();
                    return Err(error);
                }
                Ok(Self {
                    owner: Arc::new(KcpOwner {
                        shared,
                        outbound,
                        shutdown,
                        worker: Mutex::new(Some(worker)),
                        local_address,
                        peer_address,
                    }),
                    timeouts: Mutex::new(StreamTimeouts::default()),
                })
            }
            Ok(Err(error)) => {
                worker_shutdown.send_replace(true);
                let _ = worker.join();
                Err(error.to_io())
            }
            Err(std_mpsc::RecvTimeoutError::Timeout) => {
                worker_shutdown.send_replace(true);
                let _ = worker.join();
                Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "UDP/KCP connection deadline exceeded",
                ))
            }
            Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                worker_shutdown.send_replace(true);
                let _ = worker.join();
                Err(shared.current_error().map_or_else(
                    || {
                        io::Error::new(
                            io::ErrorKind::BrokenPipe,
                            "UDP/KCP worker stopped before connection completed",
                        )
                    },
                    |error| error.to_io(),
                ))
            }
        }
    }

    pub fn try_clone(&self) -> io::Result<Self> {
        let timeouts = *self
            .timeouts
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP timeout state poisoned"))?;
        Ok(Self {
            owner: Arc::clone(&self.owner),
            timeouts: Mutex::new(timeouts),
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.owner.local_address)
    }

    pub fn peer_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.owner.peer_address)
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        validate_optional_timeout(timeout)?;
        self.timeouts
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP timeout state poisoned"))?
            .read = timeout;
        Ok(())
    }

    pub fn read_timeout(&self) -> io::Result<Option<Duration>> {
        Ok(self
            .timeouts
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP timeout state poisoned"))?
            .read)
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        validate_optional_timeout(timeout)?;
        self.timeouts
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP timeout state poisoned"))?
            .write = timeout;
        Ok(())
    }

    pub fn write_timeout(&self) -> io::Result<Option<Duration>> {
        Ok(self
            .timeouts
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP timeout state poisoned"))?
            .write)
    }

    pub fn shutdown(&self, _how: Shutdown) -> io::Result<()> {
        self.owner.request_shutdown();
        Ok(())
    }
}

impl Read for KcpPeerStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let timeout = self.read_timeout()?;
        let deadline = timeout.and_then(|value| Instant::now().checked_add(value));
        let mut state = self
            .owner
            .shared
            .inbound
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP inbound state poisoned"))?;

        loop {
            if state.byte_len > 0 {
                let count = buffer.len().min(state.byte_len);
                let mut copied = 0usize;
                while copied < count {
                    let available = state
                        .chunks
                        .front()
                        .map(|chunk| chunk.len().saturating_sub(state.front_offset))
                        .expect("positive KCP byte length requires a chunk");
                    let take = available.min(count - copied);
                    let start = state.front_offset;
                    let end = start + take;
                    buffer[copied..copied + take]
                        .copy_from_slice(&state.chunks.front().expect("checked chunk")[start..end]);
                    copied += take;
                    state.front_offset = end;
                    state.byte_len -= take;
                    if state
                        .chunks
                        .front()
                        .is_some_and(|chunk| state.front_offset == chunk.len())
                    {
                        state.chunks.pop_front();
                        state.front_offset = 0;
                    }
                }
                drop(state);
                self.owner.shared.space_available.notify_one();
                return Ok(count);
            }
            if state.closed {
                return match state.error.as_ref() {
                    Some(error) => Err(error.to_io()),
                    None => Ok(0),
                };
            }

            match deadline {
                Some(deadline) => {
                    let remaining =
                        deadline
                            .checked_duration_since(Instant::now())
                            .ok_or_else(|| {
                                io::Error::new(io::ErrorKind::TimedOut, "KCP read timed out")
                            })?;
                    let (next, wait) = self
                        .owner
                        .shared
                        .readable
                        .wait_timeout(state, remaining)
                        .map_err(|_| {
                            io::Error::new(io::ErrorKind::Other, "KCP inbound state poisoned")
                        })?;
                    state = next;
                    if wait.timed_out() && state.byte_len == 0 && !state.closed {
                        return Err(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "KCP read timed out",
                        ));
                    }
                }
                None => {
                    state = self.owner.shared.readable.wait(state).map_err(|_| {
                        io::Error::new(io::ErrorKind::Other, "KCP inbound state poisoned")
                    })?;
                }
            }
        }
    }
}

impl Write for KcpPeerStream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let timeout = self.write_timeout()?;
        let deadline = timeout.and_then(|value| Instant::now().checked_add(value));
        let mut payload = buffer.to_vec();
        loop {
            if self.owner.shared.closed.load(Ordering::SeqCst) {
                return Err(self.owner.shared.current_error().map_or_else(
                    || io::Error::new(io::ErrorKind::BrokenPipe, "KCP stream is closed"),
                    |error| error.to_io(),
                ));
            }
            match self.owner.outbound.try_send(payload) {
                Ok(()) => return Ok(buffer.len()),
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "KCP outbound queue is closed",
                    ));
                }
                Err(mpsc::error::TrySendError::Full(returned)) => payload = returned,
            }
            if deadline.is_some_and(|value| Instant::now() >= value) {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "KCP write timed out waiting for queue capacity",
                ));
            }
            thread::sleep(KCP_QUEUE_WAIT_SLICE);
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        if self.owner.shared.closed.load(Ordering::SeqCst) {
            return Err(self.owner.shared.current_error().map_or_else(
                || io::Error::new(io::ErrorKind::BrokenPipe, "KCP stream is closed"),
                |error| error.to_io(),
            ));
        }
        Ok(())
    }
}

/// Transport-neutral peer stream used by protocol framing and encryption.
pub enum PeerStream {
    Tcp(TcpStream),
    Kcp(KcpPeerStream),
}

impl From<TcpStream> for PeerStream {
    fn from(stream: TcpStream) -> Self {
        Self::Tcp(stream)
    }
}

impl From<KcpPeerStream> for PeerStream {
    fn from(stream: KcpPeerStream) -> Self {
        Self::Kcp(stream)
    }
}

impl PeerStream {
    pub fn try_clone(&self) -> io::Result<Self> {
        match self {
            Self::Tcp(stream) => stream.try_clone().map(Self::Tcp),
            Self::Kcp(stream) => stream.try_clone().map(Self::Kcp),
        }
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        match self {
            Self::Tcp(stream) => stream.local_addr(),
            Self::Kcp(stream) => stream.local_addr(),
        }
    }

    pub fn peer_addr(&self) -> io::Result<SocketAddr> {
        match self {
            Self::Tcp(stream) => stream.peer_addr(),
            Self::Kcp(stream) => stream.peer_addr(),
        }
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.set_read_timeout(timeout),
            Self::Kcp(stream) => stream.set_read_timeout(timeout),
        }
    }

    pub fn read_timeout(&self) -> io::Result<Option<Duration>> {
        match self {
            Self::Tcp(stream) => stream.read_timeout(),
            Self::Kcp(stream) => stream.read_timeout(),
        }
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.set_write_timeout(timeout),
            Self::Kcp(stream) => stream.set_write_timeout(timeout),
        }
    }

    pub fn write_timeout(&self) -> io::Result<Option<Duration>> {
        match self {
            Self::Tcp(stream) => stream.write_timeout(),
            Self::Kcp(stream) => stream.write_timeout(),
        }
    }

    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.shutdown(how),
            Self::Kcp(stream) => stream.shutdown(how),
        }
    }
}

impl Read for PeerStream {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Tcp(stream) => stream.read(buffer),
            Self::Kcp(stream) => stream.read(buffer),
        }
    }
}

impl Write for PeerStream {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        match self {
            Self::Tcp(stream) => stream.write(buffer),
            Self::Kcp(stream) => stream.write(buffer),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.flush(),
            Self::Kcp(stream) => stream.flush(),
        }
    }
}

impl crate::protocol::wire::TimedRead for PeerStream {
    fn read_timeout(&self) -> io::Result<Option<Duration>> {
        PeerStream::read_timeout(self)
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        PeerStream::set_read_timeout(self, timeout)
    }
}

fn validate_optional_timeout(timeout: Option<Duration>) -> io::Result<()> {
    if timeout.is_some_and(|value| value.is_zero()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "zero duration is not a valid stream timeout",
        ));
    }
    Ok(())
}

fn validate_timeout(timeout: Duration) -> io::Result<()> {
    validate_optional_timeout(Some(timeout))
}

fn remaining(deadline: Instant, stage: &str) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|value| !value.is_zero())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                format!("UDP/KCP {stage} deadline exceeded"),
            )
        })
}

fn connect_cancelled(cancel_epoch: Option<u64>, race_cancel: &AtomicBool) -> bool {
    race_cancel.load(Ordering::Acquire) || cancel_epoch.is_some_and(crate::connect_cancelled)
}

fn ensure_connect_active(cancel_epoch: Option<u64>, race_cancel: &AtomicBool) -> io::Result<()> {
    if connect_cancelled(cancel_epoch, race_cancel) {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "UDP/KCP connection cancelled",
        ));
    }
    Ok(())
}

async fn run_kcp_worker(
    socket: UdpSocket,
    shared: Arc<KcpShared>,
    outbound: mpsc::Receiver<Vec<u8>>,
    mut shutdown: watch::Receiver<bool>,
    ready: std_mpsc::SyncSender<Result<(), StoredError>>,
    deadline: Instant,
    cancel_epoch: Option<u64>,
    race_cancel: Arc<AtomicBool>,
) -> io::Result<()> {
    let socket = Arc::new(tokio::net::UdpSocket::from_std(socket)?);
    punch_udp(
        Arc::clone(&socket),
        deadline,
        cancel_epoch,
        &race_cancel,
        &mut shutdown,
    )
    .await?;

    let mut endpoint = KcpEndpoint::new();
    endpoint.run().await;
    let input = endpoint.input_sender();
    let output = endpoint
        .output_receiver()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "KCP output receiver unavailable"))?;
    let io_shutdown = shutdown.clone();
    let mut io_task = tokio::spawn(pump_udp(socket, input, output, io_shutdown));

    let connect_timeout = remaining(deadline, "handshake")?;
    let mut connect = Box::pin(endpoint.connect(connect_timeout, 0, 0, Default::default()));
    let conn_id = loop {
        if *shutdown.borrow() || connect_cancelled(cancel_epoch, &race_cancel) {
            io_task.abort();
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "UDP/KCP connection cancelled",
            ));
        }
        remaining(deadline, "handshake")?;
        tokio::select! {
            result = &mut connect => {
                break result.map_err(|error| {
                    io::Error::new(io::ErrorKind::Other, format!("KCP handshake failed: {error}"))
                })?;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    io_task.abort();
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "UDP/KCP connection cancelled"));
                }
            }
            _ = tokio::time::sleep(Duration::from_millis(20)) => {}
        }
    };
    let stream = KcpStream::new(&endpoint, conn_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::Other,
            "KCP stream unavailable after successful handshake",
        )
    })?;
    ready.send(Ok(())).map_err(|_| {
        io::Error::new(
            io::ErrorKind::Interrupted,
            "KCP connection owner stopped before handoff",
        )
    })?;

    let (reader, writer) = tokio::io::split(stream);
    let mut read_task = Box::pin(pump_kcp_reads(reader, Arc::clone(&shared)));
    let mut write_task = Box::pin(pump_kcp_writes(writer, outbound));
    let mut stop = Box::pin(wait_for_shutdown(shutdown));

    let result = tokio::select! {
        result = &mut read_task => result,
        result = &mut write_task => result,
        result = &mut io_task => match result {
            Ok(result) => result,
            Err(error) if error.is_cancelled() => Ok(()),
            Err(error) => Err(io::Error::new(io::ErrorKind::Other, format!("KCP UDP task failed: {error}"))),
        },
        _ = &mut stop => Ok(()),
    };
    io_task.abort();
    result
}

async fn punch_udp(
    socket: Arc<tokio::net::UdpSocket>,
    route_deadline: Instant,
    cancel_epoch: Option<u64>,
    race_cancel: &AtomicBool,
    shutdown: &mut watch::Receiver<bool>,
) -> io::Result<()> {
    let punch_deadline = route_deadline.min(Instant::now() + UDP_PUNCH_MAX_DURATION);
    let mut interval = UDP_PUNCH_INITIAL_INTERVAL;
    let mut buffer = [0u8; KCP_DATAGRAM_SIZE];
    socket.send(&[]).await?;

    loop {
        if *shutdown.borrow() || connect_cancelled(cancel_epoch, race_cancel) {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "UDP punch cancelled",
            ));
        }
        let wait = remaining(punch_deadline, "punch")?.min(interval);
        tokio::select! {
            result = socket.recv(&mut buffer) => {
                result?;
                return Ok(());
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "UDP punch cancelled"));
                }
            }
            _ = tokio::time::sleep(wait) => {
                remaining(punch_deadline, "punch")?;
                socket.send(&[]).await?;
                interval = Duration::from_millis(
                    ((interval.as_millis() as u64).saturating_mul(3) / 2)
                        .min(UDP_PUNCH_MAX_INTERVAL.as_millis() as u64),
                );
            }
        }
    }
}

async fn pump_udp(
    socket: Arc<tokio::net::UdpSocket>,
    input: mpsc::Sender<KcpPacket>,
    mut output: mpsc::Receiver<KcpPacket>,
    mut shutdown: watch::Receiver<bool>,
) -> io::Result<()> {
    let mut buffer = [0u8; KCP_DATAGRAM_SIZE];
    loop {
        if *shutdown.borrow() {
            return Ok(());
        }
        tokio::select! {
            packet = output.recv() => {
                let packet = packet.ok_or_else(|| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "KCP endpoint output closed")
                })?;
                let bytes = packet.inner();
                socket.send(&bytes).await?;
            }
            result = socket.recv(&mut buffer) => {
                let size = result?;
                if size < std::mem::size_of::<KcpPacketHeader>() {
                    continue;
                }
                input
                    .send(BytesMut::from(&buffer[..size]).into())
                    .await
                    .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "KCP endpoint input closed"))?;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Ok(());
                }
            }
        }
    }
}

async fn pump_kcp_reads<R>(mut reader: R, shared: Arc<KcpShared>) -> io::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut chunk = vec![0u8; KCP_IO_CHUNK_SIZE];
    loop {
        while {
            let state = shared
                .inbound
                .lock()
                .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP inbound state poisoned"))?;
            state.byte_len >= KCP_INBOUND_CAPACITY && !state.closed
        } {
            shared.space_available.notified().await;
        }
        if shared.closed.load(Ordering::SeqCst) {
            return Ok(());
        }
        let count = reader.read(&mut chunk).await?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "KCP peer closed the byte stream",
            ));
        }
        let mut state = shared
            .inbound
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "KCP inbound state poisoned"))?;
        state.chunks.push_back(chunk[..count].to_vec());
        state.byte_len = state.byte_len.saturating_add(count);
        drop(state);
        shared.readable.notify_all();
    }
}

async fn pump_kcp_writes<W>(mut writer: W, mut outbound: mpsc::Receiver<Vec<u8>>) -> io::Result<()>
where
    W: tokio::io::AsyncWrite + Unpin,
{
    while let Some(payload) = outbound.recv().await {
        writer.write_all(&payload).await?;
        writer.flush().await?;
    }
    writer.shutdown().await
}

async fn wait_for_shutdown(mut shutdown: watch::Receiver<bool>) {
    if *shutdown.borrow() {
        return;
    }
    while shutdown.changed().await.is_ok() {
        if *shutdown.borrow() {
            return;
        }
    }
}

#[cfg(test)]
pub(crate) fn spawn_test_kcp_echo_server(
    address: SocketAddr,
    expected: Vec<u8>,
) -> io::Result<(SocketAddr, JoinHandle<io::Result<()>>)> {
    let socket = UdpSocket::bind(address)?;
    socket.set_nonblocking(true)?;
    let server_address = socket.local_addr()?;
    let handle = thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        runtime.block_on(async move {
            let socket = Arc::new(tokio::net::UdpSocket::from_std(socket)?);
            let mut punch = [0u8; KCP_DATAGRAM_SIZE];
            let (_, client_address) =
                tokio::time::timeout(Duration::from_secs(3), socket.recv_from(&mut punch))
                    .await
                    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "test punch timeout"))??;
            socket.connect(client_address).await?;
            socket.send(&[]).await?;

            let mut endpoint = KcpEndpoint::new();
            endpoint.run().await;
            let input = endpoint.input_sender();
            let output = endpoint.output_receiver().ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "test KCP output unavailable")
            })?;
            let (stop_tx, stop_rx) = watch::channel(false);
            let io_task = tokio::spawn(pump_udp(socket, input, output, stop_rx));
            let conn_id = tokio::time::timeout(Duration::from_secs(3), endpoint.accept())
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "test KCP accept timeout"))?
                .map_err(|error| {
                    io::Error::new(io::ErrorKind::Other, format!("test KCP accept: {error}"))
                })?;
            let mut stream = KcpStream::new(&endpoint, conn_id).ok_or_else(|| {
                io::Error::new(io::ErrorKind::Other, "test KCP stream unavailable")
            })?;
            let mut received = vec![0u8; expected.len()];
            tokio::time::timeout(Duration::from_secs(3), stream.read_exact(&mut received))
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "test KCP read timeout"))??;
            if received != expected {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "test KCP payload mismatch",
                ));
            }
            stream.write_all(&received).await?;
            stream.flush().await?;
            tokio::time::sleep(Duration::from_millis(300)).await;
            stop_tx.send_replace(true);
            io_task.abort();
            Ok(())
        })
    });
    Ok((server_address, handle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    fn exercise_official_kcp_loopback(server_bind: SocketAddr, client_bind: SocketAddr) {
        let payload = (0..96 * 1024)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        let (server_address, server) =
            spawn_test_kcp_echo_server(server_bind, payload.clone()).expect("bind KCP echo server");
        let socket = UdpSocket::bind(client_bind).expect("bind KCP client");
        let mut reader =
            KcpPeerStream::connect(socket, server_address, Duration::from_secs(3), None)
                .expect("connect official KCP endpoint");
        let mut writer = reader.try_clone().expect("clone KCP stream");
        writer
            .write_all(&payload)
            .expect("write through cloned KCP stream");
        let mut echoed = vec![0u8; payload.len()];
        reader
            .read_exact(&mut echoed)
            .expect("read KCP echo payload");
        assert_eq!(echoed, payload);

        reader
            .set_read_timeout(Some(Duration::from_millis(40)))
            .expect("set KCP read timeout");
        let mut byte = [0u8; 1];
        let error = reader
            .read(&mut byte)
            .expect_err("idle KCP read must honor timeout");
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        reader
            .shutdown(Shutdown::Both)
            .expect("shutdown KCP stream");
        server.join().expect("join KCP echo server").unwrap();
    }

    #[test]
    fn official_kcp_stream_round_trips_over_ipv4() {
        exercise_official_kcp_loopback(
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0),
        );
    }

    #[test]
    fn official_kcp_stream_round_trips_over_ipv6() {
        let server = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 0);
        if UdpSocket::bind(server).is_err() {
            eprintln!("IPv6 loopback unavailable; skipping KCP IPv6 transport test");
            return;
        }
        exercise_official_kcp_loopback(server, server);
    }

    #[test]
    fn kcp_handshake_observes_the_session_connect_epoch() {
        let server = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind punch fixture");
        server
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("bound fixture timeout");
        let server_address = server.local_addr().expect("punch fixture address");
        let fixture = thread::spawn(move || {
            let mut packet = [0u8; KCP_DATAGRAM_SIZE];
            let (_, peer) = server.recv_from(&mut packet).expect("receive UDP punch");
            server.send_to(&[], peer).expect("answer UDP punch");
            thread::sleep(Duration::from_millis(250));
        });

        let session_id = 0x4B43_5001;
        let epoch = crate::begin_connect_epoch(session_id);
        let canceller = thread::spawn(move || {
            thread::sleep(Duration::from_millis(60));
            crate::cancel_connect_epoch(epoch);
        });
        let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind KCP client");
        let started = Instant::now();
        let error =
            KcpPeerStream::connect(socket, server_address, Duration::from_secs(2), Some(epoch))
                .err()
                .expect("cancelled KCP handshake must fail");
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(started.elapsed() < Duration::from_millis(750));

        canceller.join().expect("join KCP canceller");
        fixture.join().expect("join punch fixture");
        crate::finish_connect_epoch(epoch, session_id);
    }

    #[test]
    fn kcp_handshake_observes_the_transport_race_token() {
        let server = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind punch fixture");
        server
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("bound fixture timeout");
        let server_address = server.local_addr().expect("punch fixture address");
        let fixture = thread::spawn(move || {
            let mut packet = [0u8; KCP_DATAGRAM_SIZE];
            let (_, peer) = server.recv_from(&mut packet).expect("receive UDP punch");
            server.send_to(&[], peer).expect("answer UDP punch");
            thread::sleep(Duration::from_millis(250));
        });

        let race_cancel = Arc::new(AtomicBool::new(false));
        let canceller_token = Arc::clone(&race_cancel);
        let canceller = thread::spawn(move || {
            thread::sleep(Duration::from_millis(60));
            canceller_token.store(true, Ordering::Release);
        });
        let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind KCP client");
        let started = Instant::now();
        let error = KcpPeerStream::connect_with_race_cancel(
            socket,
            server_address,
            Duration::from_secs(2),
            None,
            race_cancel,
        )
        .err()
        .expect("race-cancelled KCP handshake must fail");
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(started.elapsed() < Duration::from_millis(750));

        canceller.join().expect("join KCP race canceller");
        fixture.join().expect("join punch fixture");
    }
}
