// crypto_channel.rs — RustDesk 加密 TCP 通道
//
// 加密 payload 外层仍使用 RustDesk BytesCodec 帧:
//   [BytesCodec length] [secretbox encrypted protobuf payload]

use super::crypto;
use super::protocol::wire;
use std::io::{self, Read};
use std::net::TcpStream;
use std::time::Duration;

const MAX_NONCE_RECOVERY_SKIP: u64 = 4096;
const MAX_DECRYPT_RESYNC_FRAMES: usize = 8;

/// 加密 peer 通道。
pub struct CryptoChannel {
    stream: TcpStream,
    tx_key: [u8; 32],
    rx_key: [u8; 32],
    tx_nonce: u64,
    rx_nonce: u64,
    rx_buffer: Vec<u8>,
}

impl CryptoChannel {
    pub fn new(stream: TcpStream, tx_key: &[u8; 32], rx_key: &[u8; 32]) -> Self {
        Self {
            stream,
            tx_key: *tx_key,
            rx_key: *rx_key,
            tx_nonce: 0,
            rx_nonce: 0,
            rx_buffer: Vec::new(),
        }
    }

    /// 发送加密帧。nonce 仅在 TCP 写入成功后递增。
    pub fn send(&mut self, plaintext: &[u8]) -> io::Result<()> {
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
        let mut dropped_bad_frames = 0usize;
        let mut first_failure = None;

        loop {
            let ciphertext = match self.read_ciphertext_frame() {
                Ok(ciphertext) => ciphertext,
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

    fn read_ciphertext_frame(&mut self) -> io::Result<Vec<u8>> {
        loop {
            if let Some(frame) = try_take_frame(&mut self.rx_buffer)? {
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
                Ok(n) => self.rx_buffer.extend_from_slice(&chunk[..n]),
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
    pub fn stream(&self) -> &TcpStream {
        &self.stream
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.set_read_timeout(timeout)
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
    use std::net::TcpListener;
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
