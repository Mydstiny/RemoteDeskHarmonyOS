// crypto_channel.rs — RustDesk 加密 TCP 通道
//
// 加密 payload 外层仍使用 RustDesk BytesCodec 帧:
//   [BytesCodec length] [secretbox encrypted protobuf payload]

use super::crypto;
use super::peer_stream::PeerStream;
use super::protocol::wire;
use std::collections::VecDeque;
use std::io::{self, Read};
use std::net::Shutdown;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const MAX_NONCE_RECOVERY_SKIP: u64 = 4096;
const MAX_DECRYPT_RESYNC_FRAMES: usize = 8;
const STREAMING_CONTROL_QUEUE_CAPACITY: usize = 128;
const STREAMING_CONTROL_WAIT_SLICE_MS: u64 = 100;
const STREAMING_WRITE_TIMEOUT_MS: u64 = 3000;
const STREAMING_ACK_AFTER_CONTROLS: usize = 8;

/// 加密 peer 通道。
pub struct CryptoChannel {
    stream: PeerStream,
    encrypted: bool,
    tx_key: [u8; 32],
    rx_key: [u8; 32],
    tx_nonce: u64,
    rx_nonce: u64,
    rx_buffer: Vec<u8>,
    streaming_writer: Option<StreamingWriter>,
}

impl CryptoChannel {
    pub fn new<S>(stream: S, tx_key: &[u8; 32], rx_key: &[u8; 32]) -> Self
    where
        S: Into<PeerStream>,
    {
        Self {
            stream: stream.into(),
            encrypted: true,
            tx_key: *tx_key,
            rx_key: *rx_key,
            tx_nonce: 0,
            rx_nonce: 0,
            rx_buffer: Vec::new(),
            streaming_writer: None,
        }
    }

    /// Create the plain peer channel used by RustDesk's explicit LAN/direct
    /// listener.  A direct listener is not the rendezvous secure channel: it
    /// sends the login Hash immediately and then exchanges framed protobuf
    /// messages without the SignedId/PublicKey negotiation.
    pub fn new_plain<S>(stream: S) -> Self
    where
        S: Into<PeerStream>,
    {
        Self {
            stream: stream.into(),
            encrypted: false,
            tx_key: [0u8; 32],
            rx_key: [0u8; 32],
            tx_nonce: 0,
            rx_nonce: 0,
            rx_buffer: Vec::new(),
            streaming_writer: None,
        }
    }

    /// 发送加密帧。nonce 仅在 TCP 写入成功后递增。
    pub fn send(&mut self, plaintext: &[u8]) -> io::Result<()> {
        if let Some(writer) = self.streaming_writer.as_ref() {
            return writer.enqueue_control(plaintext);
        }
        self.send_direct(plaintext)
    }

    /// Send a streaming acknowledgement without allowing it to delay input.
    /// When the negotiated login mode requires acknowledgements, the streaming
    /// writer preserves one encoder credit for every received video frame.
    pub fn send_low_priority(&mut self, plaintext: &[u8]) -> io::Result<()> {
        if let Some(writer) = self.streaming_writer.as_ref() {
            return writer.enqueue_ack(plaintext);
        }
        self.send_direct(plaintext)
    }

    /// Move all streaming writes to one owner so encrypted nonces and TCP
    /// frames cannot be interleaved by the receive and input paths.
    pub fn start_streaming_writer(&mut self) -> io::Result<()> {
        if self.streaming_writer.is_some() {
            return Ok(());
        }
        let stream = self.stream.try_clone()?;
        self.streaming_writer = Some(StreamingWriter::start(
            stream,
            self.encrypted,
            self.tx_key,
            self.tx_nonce,
        )?);
        Ok(())
    }

    /// Surface an asynchronous writer failure to the receive/control loop.
    /// Without this check the UI can remain connected after the single writer
    /// has died, leaving both video refresh and input messages ineffective.
    pub fn check_streaming_writer(&self) -> io::Result<()> {
        let Some(writer) = self.streaming_writer.as_ref() else {
            return Ok(());
        };
        writer.check_error()
    }

    fn send_direct(&mut self, plaintext: &[u8]) -> io::Result<()> {
        if !self.encrypted {
            wire::write_frame(&mut self.stream, plaintext)?;
            return Ok(());
        }
        let next_nonce = self.tx_nonce.wrapping_add(1);
        let mut nonce = [0u8; 24];
        nonce[..8].copy_from_slice(&next_nonce.to_le_bytes());

        let ciphertext = crypto::secretbox_encrypt(plaintext, &nonce, &self.tx_key)
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "encryption failed"))?;

        wire::write_frame(&mut self.stream, &ciphertext)?;
        self.tx_nonce = next_nonce;
        Ok(())
    }

    /// 接收并解密一帧。
    ///
    /// RustDesk upstream 先递增 encrypted sequence 再使用，所以正常用 rx_nonce + 1 解密。
    /// streaming 阶段有短 read timeout，必须保留半包，否则超时会造成 BytesCodec 边界错位。
    pub fn recv(&mut self) -> io::Result<Vec<u8>> {
        self.recv_with_pump(|_| Ok(()))
    }

    /// 接收并解密一帧，同时在大型帧的分片读取之间让调用方发送控制消息。
    ///
    /// RustDesk 的视频帧和鼠标/键盘控制共用一条全双工 TCP 连接。只依赖
    /// `read_timeout` 不能限制“持续有数据到达”的大帧读取时间，因此控制消息
    /// 必须在每次 `read` 后被优先处理。streaming 阶段的回调只把控制消息交给
    /// 单写端排队，读取缓冲仍由本对象独占，半包在超时后会保留给下一次调用。
    pub fn recv_with_pump<P>(&mut self, mut pump: P) -> io::Result<Vec<u8>>
    where
        P: FnMut(&mut Self) -> io::Result<()>,
    {
        if !self.encrypted {
            return self.read_plain_frame_with_pump(&mut pump);
        }
        let mut dropped_bad_frames = 0usize;
        let mut first_failure = None;

        loop {
            let ciphertext = match self.read_ciphertext_frame_with_pump(&mut pump) {
                Ok(ciphertext) => ciphertext,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => return Err(err),
                Err(err) if dropped_bad_frames > 0 => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        format!(
                            "{} dropped_bad_frames={} next_read_error kind={:?} msg={}",
                            first_failure.unwrap_or_else(|| "decryption failed".to_string()),
                            dropped_bad_frames,
                            err.kind(),
                            err
                        ),
                    ));
                }
                Err(err) => return Err(err),
            };

            if let Some(plaintext) = self.try_decrypt(&ciphertext) {
                if dropped_bad_frames > 0 {
                    eprintln!(
                        "[RustDesk-FFI] crypto: resynchronized after dropping {} undecryptable frame(s), rx_nonce={}",
                        dropped_bad_frames,
                        self.rx_nonce
                    );
                }
                return Ok(plaintext);
            }

            let detail = self.decrypt_failure_detail(&ciphertext);
            if first_failure.is_none() {
                first_failure = Some(detail.clone());
            }

            if dropped_bad_frames >= MAX_DECRYPT_RESYNC_FRAMES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{} dropped_bad_frames={}", detail, dropped_bad_frames),
                ));
            }

            dropped_bad_frames += 1;
            eprintln!(
                "[RustDesk-FFI] crypto: dropping undecryptable frame #{} {}",
                dropped_bad_frames, detail
            );
        }
    }

    fn read_plain_frame_with_pump<P>(&mut self, pump: &mut P) -> io::Result<Vec<u8>>
    where
        P: FnMut(&mut Self) -> io::Result<()>,
    {
        loop {
            if let Some(frame) = try_take_frame(&mut self.rx_buffer)? {
                // A complete video frame can already be buffered after the
                // previous read. Pump once before returning it so control
                // input is not delayed until the next network read.
                pump(self)?;
                return Ok(frame);
            }

            let mut chunk = [0u8; 8192];
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "connection closed while reading plain frame",
                    ));
                }
                Ok(n) => {
                    self.rx_buffer.extend_from_slice(&chunk[..n]);
                    pump(self)?;
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }
    }

    fn read_ciphertext_frame_with_pump<P>(&mut self, pump: &mut P) -> io::Result<Vec<u8>>
    where
        P: FnMut(&mut Self) -> io::Result<()>,
    {
        loop {
            if let Some(frame) = try_take_frame(&mut self.rx_buffer)? {
                // Keep the control path live even when several complete
                // ciphertext frames arrived in one TCP read.
                pump(self)?;
                return Ok(frame);
            }

            let mut chunk = [0u8; 8192];
            match self.stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::UnexpectedEof,
                        "connection closed while reading frame",
                    ));
                }
                Ok(n) => {
                    self.rx_buffer.extend_from_slice(&chunk[..n]);
                    pump(self)?;
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }
    }

    fn try_decrypt(&mut self, ciphertext: &[u8]) -> Option<Vec<u8>> {
        for skip in 1u64..=MAX_NONCE_RECOVERY_SKIP {
            let candidate = self.rx_nonce.wrapping_add(skip);
            let mut nonce = [0u8; 24];
            nonce[..8].copy_from_slice(&candidate.to_le_bytes());

            if let Some(plaintext) = crypto::secretbox_decrypt(ciphertext, &nonce, &self.rx_key) {
                if skip > 1 {
                    eprintln!(
                        "[RustDesk-FFI] crypto: recovered from nonce skip {} -> {} (skipped {})",
                        self.rx_nonce.wrapping_add(1),
                        candidate,
                        skip - 1
                    );
                }
                self.rx_nonce = candidate;
                return Some(plaintext);
            }
        }
        None
    }

    fn decrypt_failure_detail(&self, ciphertext: &[u8]) -> String {
        format!(
            "decryption failed at rx_nonce={} tried_next={}..{} ciphertext_len={} head_hex=[{}] head_ascii='{}'",
            self.rx_nonce,
            self.rx_nonce.wrapping_add(1),
            self.rx_nonce.wrapping_add(MAX_NONCE_RECOVERY_SKIP),
            ciphertext.len(),
            bytes_hex(ciphertext, 16),
            bytes_ascii(ciphertext, 16)
        )
    }

    #[allow(dead_code)]
    pub fn stream(&self) -> &PeerStream {
        &self.stream
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(timeout)
    }

    pub fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_write_timeout(timeout)
    }
}

struct CryptoWriter {
    stream: PeerStream,
    encrypted: bool,
    tx_key: [u8; 32],
    tx_nonce: u64,
}

impl CryptoWriter {
    fn send(&mut self, plaintext: &[u8]) -> io::Result<()> {
        if !self.encrypted {
            wire::write_frame(&mut self.stream, plaintext)?;
            return Ok(());
        }

        let next_nonce = self.tx_nonce.wrapping_add(1);
        let mut nonce = [0u8; 24];
        nonce[..8].copy_from_slice(&next_nonce.to_le_bytes());
        let ciphertext = crypto::secretbox_encrypt(plaintext, &nonce, &self.tx_key)
            .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "encryption failed"))?;
        wire::write_frame(&mut self.stream, &ciphertext)?;
        self.tx_nonce = next_nonce;
        Ok(())
    }
}

struct StreamingWriterState {
    control: VecDeque<Vec<u8>>,
    ack_payload: Option<Vec<u8>>,
    pending_acks: u64,
    controls_since_ack: usize,
    closed: bool,
    error: Option<String>,
}

struct StreamingWriterShared {
    state: Mutex<StreamingWriterState>,
    wake: Condvar,
}

impl StreamingWriterShared {
    fn new() -> Self {
        Self {
            state: Mutex::new(StreamingWriterState {
                control: VecDeque::new(),
                ack_payload: None,
                pending_acks: 0,
                controls_since_ack: 0,
                closed: false,
                error: None,
            }),
            wake: Condvar::new(),
        }
    }

    fn set_error(&self, error: io::Error) {
        if let Ok(mut state) = self.state.lock() {
            state.error = Some(error.to_string());
            state.closed = true;
        }
        self.wake.notify_all();
    }

    fn take_next(&self) -> Option<Vec<u8>> {
        let mut state = self.state.lock().ok()?;
        loop {
            // Every video_received message returns one encoder credit to the
            // peer. Keep the payload once but preserve the exact ACK count;
            // coalescing several boolean ACK messages into one throttles the
            // remote encoder and produces bursty video with long frame gaps.
            if state.pending_acks > 0 && state.controls_since_ack >= STREAMING_ACK_AFTER_CONTROLS {
                let payload = take_ack(&mut state)?;
                drop(state);
                self.wake.notify_all();
                return Some(payload);
            }
            if let Some(payload) = state.control.pop_front() {
                state.controls_since_ack = state.controls_since_ack.saturating_add(1);
                drop(state);
                self.wake.notify_all();
                return Some(payload);
            }
            if state.pending_acks > 0 {
                let payload = take_ack(&mut state)?;
                drop(state);
                self.wake.notify_all();
                return Some(payload);
            }
            if state.closed {
                return None;
            }
            state = self.wake.wait(state).ok()?;
        }
    }

    fn check_error(&self) -> io::Result<()> {
        let state = self
            .state
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "streaming writer poisoned"))?;
        if let Some(error) = state.error.as_ref() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, error.clone()));
        }
        if state.closed {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "streaming writer closed",
            ));
        }
        Ok(())
    }
}

fn take_ack(state: &mut StreamingWriterState) -> Option<Vec<u8>> {
    if state.pending_acks == 0 {
        return None;
    }
    let payload = state.ack_payload.as_ref()?.clone();
    state.pending_acks -= 1;
    state.controls_since_ack = 0;
    if state.pending_acks == 0 {
        state.ack_payload = None;
    }
    Some(payload)
}

struct StreamingWriter {
    shared: Arc<StreamingWriterShared>,
    stop_stream: Option<PeerStream>,
    join: Option<JoinHandle<()>>,
}

impl StreamingWriter {
    fn start(
        stream: PeerStream,
        encrypted: bool,
        tx_key: [u8; 32],
        tx_nonce: u64,
    ) -> io::Result<Self> {
        stream.set_write_timeout(Some(Duration::from_millis(STREAMING_WRITE_TIMEOUT_MS)))?;
        let stop_stream = stream.try_clone()?;
        let shared = Arc::new(StreamingWriterShared::new());
        let thread_shared = Arc::clone(&shared);
        let join = thread::spawn(move || {
            let mut writer = CryptoWriter {
                stream,
                encrypted,
                tx_key,
                tx_nonce,
            };
            while let Some(payload) = thread_shared.take_next() {
                if let Err(error) = writer.send(&payload) {
                    thread_shared.set_error(error);
                    break;
                }
            }
        });
        Ok(Self {
            shared,
            stop_stream: Some(stop_stream),
            join: Some(join),
        })
    }

    fn enqueue_control(&self, plaintext: &[u8]) -> io::Result<()> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "streaming writer poisoned"))?;
        loop {
            if let Some(error) = state.error.as_ref() {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, error.clone()));
            }
            if state.closed {
                return Err(io::Error::new(
                    io::ErrorKind::NotConnected,
                    "streaming writer closed",
                ));
            }
            if state.control.len() < STREAMING_CONTROL_QUEUE_CAPACITY {
                state.control.push_back(plaintext.to_vec());
                drop(state);
                self.shared.wake.notify_one();
                return Ok(());
            }

            let (next_state, wait_result) = self
                .shared
                .wake
                .wait_timeout(
                    state,
                    Duration::from_millis(STREAMING_CONTROL_WAIT_SLICE_MS),
                )
                .map_err(|_| io::Error::new(io::ErrorKind::Other, "streaming writer poisoned"))?;
            state = next_state;
            // A timeout is only a polling slice. Keep the control event until
            // the writer makes room or reports a real socket failure; turning
            // queue pressure into WouldBlock here used to tear down healthy
            // sessions and caused needless reconnects/input loss.
            let _ = wait_result;
        }
    }

    fn check_error(&self) -> io::Result<()> {
        self.shared.check_error()
    }

    fn enqueue_ack(&self, plaintext: &[u8]) -> io::Result<()> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::new(io::ErrorKind::Other, "streaming writer poisoned"))?;
        if let Some(error) = state.error.as_ref() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, error.clone()));
        }
        if state.closed {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "streaming writer closed",
            ));
        }
        state.ack_payload = Some(plaintext.to_vec());
        state.pending_acks = state.pending_acks.checked_add(1).ok_or_else(|| {
            io::Error::new(io::ErrorKind::Other, "streaming video ACK count overflow")
        })?;
        drop(state);
        self.shared.wake.notify_one();
        Ok(())
    }
}

impl Drop for StreamingWriter {
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.state.lock() {
            state.closed = true;
        }
        self.shared.wake.notify_all();
        // A blocked write must be interrupted before joining the owner. This
        // only runs when the channel itself is being torn down.
        if let Some(stream) = self.stop_stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn try_take_frame(buffer: &mut Vec<u8>) -> io::Result<Option<Vec<u8>>> {
    if buffer.is_empty() {
        return Ok(None);
    }

    let head_len = ((buffer[0] & 0x03) + 1) as usize;
    if buffer.len() < head_len {
        return Ok(None);
    }

    let mut n = buffer[0] as usize;
    if head_len > 1 {
        n |= (buffer[1] as usize) << 8;
    }
    if head_len > 2 {
        n |= (buffer[2] as usize) << 16;
    }
    if head_len > 3 {
        n |= (buffer[3] as usize) << 24;
    }
    let len = n >> 2;

    if len > wire::MAX_FRAME_SIZE {
        let mut head = [0u8; 4];
        head[..head_len].copy_from_slice(&buffer[..head_len]);
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "frame too large: {} bytes (max {}) header_len={} header_hex=[{}] header_ascii='{}'",
                len,
                wire::MAX_FRAME_SIZE,
                head_len,
                bytes_hex(&head[..head_len], head_len),
                bytes_ascii(&head[..head_len], head_len),
            ),
        ));
    }

    let frame_end = head_len + len;
    if buffer.len() < frame_end {
        return Ok(None);
    }

    buffer.drain(..head_len);
    Ok(Some(buffer.drain(..len).collect()))
}

fn bytes_hex(bytes: &[u8], limit: usize) -> String {
    bytes
        .iter()
        .take(limit)
        .map(|byte| format!("{:02X}", byte))
        .collect::<Vec<_>>()
        .join(" ")
}

fn bytes_ascii(bytes: &[u8], limit: usize) -> String {
    bytes
        .iter()
        .take(limit)
        .map(|byte| {
            if (0x20..=0x7e).contains(byte) {
                *byte as char
            } else {
                '.'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};
    use std::thread;
    use std::time::Duration;

    #[test]
    fn first_sent_frame_uses_upstream_nonce_one() {
        let key = [7u8; 32];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let ciphertext = wire::read_frame(&mut stream).unwrap();
            let nonce_one = crypto::secretbox_nonce(1);
            let plaintext =
                crypto::secretbox_decrypt(&ciphertext, &nonce_one, &key).expect("nonce 1");
            assert_eq!(plaintext, b"login-request");

            let nonce_zero = crypto::secretbox_nonce(0);
            assert!(
                crypto::secretbox_decrypt(&ciphertext, &nonce_zero, &key).is_none(),
                "upstream framing must not use nonce 0 for the first encrypted payload"
            );
        });

        let stream = TcpStream::connect(addr).unwrap();
        let mut channel = CryptoChannel::new(stream, &key, &key);
        channel.send(b"login-request").unwrap();
        handle.join().unwrap();
    }

    #[test]
    fn timed_out_split_frame_is_buffered_for_next_recv() {
        let key = [9u8; 32];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();

        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let nonce = crypto::secretbox_nonce(1);
            let ciphertext = crypto::secretbox_encrypt(b"split-payload", &nonce, &key).unwrap();
            let frame = encode_frame(&ciphertext);
            let split_at = frame.len() / 2;
            stream.write_all(&frame[..split_at]).unwrap();
            stream.flush().unwrap();
            thread::sleep(Duration::from_millis(120));
            stream.write_all(&frame[split_at..]).unwrap();
            stream.flush().unwrap();
        });

        let stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        let mut channel = CryptoChannel::new(stream, &key, &key);

        match channel.recv() {
            Ok(plaintext) => assert_eq!(plaintext, b"split-payload"),
            Err(err)
                if err.kind() == io::ErrorKind::WouldBlock
                    || err.kind() == io::ErrorKind::TimedOut =>
            {
                thread::sleep(Duration::from_millis(150));
                let plaintext = channel.recv().unwrap();
                assert_eq!(plaintext, b"split-payload");
            }
            Err(err) => panic!("unexpected recv error: {err}"),
        }

        handle.join().unwrap();
    }

    #[test]
    fn plain_channel_round_trips_unencrypted_peer_frame() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            wire::write_frame(&mut stream, b"hash-challenge").unwrap();
            let login = wire::read_frame(&mut stream).unwrap();
            assert_eq!(login, b"login-request");
        });

        let stream = TcpStream::connect(addr).unwrap();
        let mut channel = CryptoChannel::new_plain(stream);
        assert_eq!(channel.recv().unwrap(), b"hash-challenge");
        channel.send(b"login-request").unwrap();
        handle.join().unwrap();
    }

    #[test]
    fn recv_with_pump_sends_control_before_large_frame_finishes() {
        let key = [11u8; 32];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let nonce = crypto::secretbox_nonce(1);
            let payload = vec![0x5Au8; 128 * 1024];
            let ciphertext = crypto::secretbox_encrypt(&payload, &nonce, &key).unwrap();
            let frame = encode_frame(&ciphertext);
            let split_at = frame.len() / 2;
            stream.write_all(&frame[..split_at]).unwrap();
            stream.flush().unwrap();

            let control_ciphertext = wire::read_frame(&mut stream).unwrap();
            let control_nonce = crypto::secretbox_nonce(1);
            let control = crypto::secretbox_decrypt(&control_ciphertext, &control_nonce, &key)
                .expect("control frame should be encrypted with nonce one");
            assert_eq!(control, b"mouse-control");

            stream.write_all(&frame[split_at..]).unwrap();
            stream.flush().unwrap();
        });

        let stream = TcpStream::connect(addr).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let mut channel = CryptoChannel::new(stream, &key, &key);
        let mut pump_calls = 0usize;
        let payload = channel
            .recv_with_pump(|channel| {
                pump_calls += 1;
                if pump_calls == 1 {
                    channel.send(b"mouse-control")?;
                }
                Ok(())
            })
            .unwrap();
        assert_eq!(payload.len(), 128 * 1024);
        assert!(pump_calls >= 1);
        handle.join().unwrap();
    }

    #[test]
    fn streaming_writer_preserves_nonce_order_for_control_and_ack() {
        let key = [13u8; 32];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            for (expected_nonce, expected_payload) in [
                (1u64, b"mouse-control".as_slice()),
                (2u64, b"video-ack".as_slice()),
            ] {
                let ciphertext = wire::read_frame(&mut stream).unwrap();
                let plaintext = crypto::secretbox_decrypt(
                    &ciphertext,
                    &crypto::secretbox_nonce(expected_nonce),
                    &key,
                )
                .expect("writer nonce must stay ordered");
                assert_eq!(plaintext, expected_payload);
            }
        });

        let stream = TcpStream::connect(addr).unwrap();
        let mut channel = CryptoChannel::new(stream, &key, &key);
        channel.start_streaming_writer().unwrap();
        channel.send(b"mouse-control").unwrap();
        channel.send_low_priority(b"video-ack").unwrap();
        handle.join().unwrap();
    }

    #[test]
    fn ack_backlog_preserves_every_encoder_credit_without_blocking_control_queue() {
        let shared = Arc::new(StreamingWriterShared::new());
        let writer = StreamingWriter {
            shared: Arc::clone(&shared),
            stop_stream: None,
            join: None,
        };

        for _ in 0..5 {
            writer.enqueue_ack(b"video-ack").unwrap();
        }
        writer.enqueue_control(b"mouse-control").unwrap();

        {
            let state = shared.state.lock().unwrap();
            assert_eq!(
                state.control.front().map(Vec::as_slice),
                Some(b"mouse-control".as_slice())
            );
            assert_eq!(state.ack_payload.as_deref(), Some(b"video-ack".as_slice()));
            assert_eq!(state.pending_acks, 5);
        }

        assert_eq!(shared.take_next().unwrap(), b"mouse-control");
        for _ in 0..5 {
            assert_eq!(shared.take_next().unwrap(), b"video-ack");
        }
        let state = shared.state.lock().unwrap();
        assert_eq!(state.pending_acks, 0);
        assert!(state.ack_payload.is_none());
    }

    #[test]
    fn streaming_writer_inserts_ack_during_a_control_burst() {
        let shared = Arc::new(StreamingWriterShared::new());
        let writer = StreamingWriter {
            shared: Arc::clone(&shared),
            stop_stream: None,
            join: None,
        };

        for index in 0..=STREAMING_ACK_AFTER_CONTROLS {
            writer
                .enqueue_control(format!("control-{index}").as_bytes())
                .unwrap();
        }
        writer.enqueue_ack(b"video-ack").unwrap();

        let mut emitted = Vec::new();
        for _ in 0..=STREAMING_ACK_AFTER_CONTROLS {
            emitted.push(shared.take_next().expect("queued payload"));
        }
        assert!(emitted[..STREAMING_ACK_AFTER_CONTROLS]
            .iter()
            .all(|payload| payload.starts_with(b"control-")));
        assert_eq!(emitted[STREAMING_ACK_AFTER_CONTROLS], b"video-ack");
    }

    #[test]
    fn streaming_writer_waits_for_transient_control_capacity_pressure() {
        let shared = Arc::new(StreamingWriterShared::new());
        let writer = StreamingWriter {
            shared: Arc::clone(&shared),
            stop_stream: None,
            join: None,
        };
        {
            let mut state = shared.state.lock().unwrap();
            state
                .control
                .extend((0..STREAMING_CONTROL_QUEUE_CAPACITY).map(|index| vec![index as u8]));
        }

        let consumer_shared = Arc::clone(&shared);
        let consumer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(10));
            consumer_shared.take_next().expect("full queue payload");
        });
        writer
            .enqueue_control(b"after-transient-pressure")
            .expect("writer should wait for one queue slot");
        consumer.join().unwrap();
    }

    fn encode_frame(payload: &[u8]) -> Vec<u8> {
        let len = payload.len();
        let mut out = Vec::new();
        if len <= 0x3F {
            out.push((len << 2) as u8);
        } else if len <= 0x3FFF {
            out.extend_from_slice(&((len << 2) as u16 | 0x01).to_le_bytes());
        } else if len <= 0x3FFFFF {
            let head = (len << 2) as u32 | 0x02;
            out.push((head & 0xFF) as u8);
            out.push(((head >> 8) & 0xFF) as u8);
            out.push(((head >> 16) & 0xFF) as u8);
        } else {
            out.extend_from_slice(&((len << 2) as u32 | 0x03).to_le_bytes());
        }
        out.extend_from_slice(payload);
        out
    }
}
