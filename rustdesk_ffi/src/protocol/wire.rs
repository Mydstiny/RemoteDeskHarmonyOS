// wire.rs — RustDesk TCP 帧协议
//
// RustDesk upstream 使用 hbb_common::BytesCodec:
//   头部低 2 位表示头部长度 (1-4 bytes)，其余位表示 payload 长度。
//   payload 是 protobuf 序列化后的消息体。
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

/// TCP 帧最大大小 (16MB，覆盖常见视频帧)
pub const MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;
const CANCELLABLE_READ_SLICE: Duration = Duration::from_millis(200);

/// 读取一帧，返回 payload 字节数组。
pub fn read_frame(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let header = read_len_with_header(stream)?;
    let len = header.len;

    if len > MAX_FRAME_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "frame too large: {} bytes (max {}) header_len={} header_hex=[{}] header_ascii='{}'",
                len,
                MAX_FRAME_SIZE,
                header.head_len,
                header_hex(&header.head, header.head_len),
                header_ascii(&header.head, header.head_len),
            ),
        ));
    }

    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    Ok(payload)
}

/// Read one complete frame while retaining partial header/payload bytes across
/// socket timeouts. The caller supplies one absolute deadline so DNS/connect
/// and protocol handshakes can share a bounded cancellation contract.
pub fn read_frame_cancellable<F>(
    stream: &mut TcpStream,
    deadline: Instant,
    mut cancelled: F,
) -> io::Result<Vec<u8>>
where
    F: FnMut() -> bool,
{
    let original_timeout = stream.read_timeout()?;
    let result = (|| {
        let mut first = [0u8; 1];
        read_exact_until(stream, &mut first, deadline, false, &mut cancelled)?;

        let head_len = ((first[0] & 0x03) + 1) as usize;
        let mut head = [0u8; 4];
        head[0] = first[0];
        if head_len > 1 {
            read_exact_until(
                stream,
                &mut head[1..head_len],
                deadline,
                true,
                &mut cancelled,
            )?;
        }

        let len = decode_frame_length(&head, head_len);
        if len > MAX_FRAME_SIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "frame too large: {} bytes (max {}) header_len={} header_hex=[{}] header_ascii='{}'",
                    len,
                    MAX_FRAME_SIZE,
                    head_len,
                    header_hex(&head, head_len),
                    header_ascii(&head, head_len),
                ),
            ));
        }

        let mut payload = vec![0u8; len];
        read_exact_until(stream, &mut payload, deadline, true, &mut cancelled)?;
        Ok(payload)
    })();

    let restore_result = stream.set_read_timeout(original_timeout);
    match (result, restore_result) {
        (Ok(payload), Ok(())) => Ok(payload),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), _) => Err(error),
    }
}

fn read_exact_until<F>(
    stream: &mut TcpStream,
    buffer: &mut [u8],
    deadline: Instant,
    frame_started: bool,
    cancelled: &mut F,
) -> io::Result<()>
where
    F: FnMut() -> bool,
{
    let mut offset = 0usize;
    while offset < buffer.len() {
        if cancelled() {
            return Err(io::Error::new(
                io::ErrorKind::Interrupted,
                "connection cancelled while reading frame",
            ));
        }
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or_else(|| frame_deadline_error(frame_started || offset > 0))?;
        let poll_timeout = remaining.min(CANCELLABLE_READ_SLICE);
        if poll_timeout.is_zero() {
            return Err(frame_deadline_error(frame_started || offset > 0));
        }
        stream.set_read_timeout(Some(poll_timeout))?;
        match stream.read(&mut buffer[offset..]) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "connection closed while reading frame",
                ));
            }
            Ok(read) => offset += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error)
                if error.kind() == io::ErrorKind::TimedOut
                    || error.kind() == io::ErrorKind::WouldBlock =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn frame_deadline_error(frame_started: bool) -> io::Error {
    if frame_started {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "frame read deadline exceeded after partial frame",
        )
    } else {
        io::Error::new(io::ErrorKind::TimedOut, "frame read deadline exceeded")
    }
}

/// 写入一帧。
pub fn write_frame(stream: &mut TcpStream, payload: &[u8]) -> io::Result<()> {
    let len = payload.len();
    if len > MAX_FRAME_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: {} bytes", len),
        ));
    }

    write_len(stream, len)?;
    stream.write_all(payload)?;
    stream.flush()?;
    Ok(())
}

#[derive(Debug, Clone, Copy)]
struct FrameHeader {
    len: usize,
    head_len: usize,
    head: [u8; 4],
}

fn read_len_with_header<R: Read>(reader: &mut R) -> io::Result<FrameHeader> {
    let mut first = [0u8; 1];
    reader.read_exact(&mut first)?;

    let head_len = ((first[0] & 0x03) + 1) as usize;
    let mut head = [0u8; 4];
    head[0] = first[0];
    if head_len > 1 {
        reader.read_exact(&mut head[1..head_len])?;
    }

    Ok(FrameHeader {
        len: decode_frame_length(&head, head_len),
        head_len,
        head,
    })
}

fn decode_frame_length(head: &[u8; 4], head_len: usize) -> usize {
    let mut encoded = head[0] as usize;
    if head_len > 1 {
        encoded |= (head[1] as usize) << 8;
    }
    if head_len > 2 {
        encoded |= (head[2] as usize) << 16;
    }
    if head_len > 3 {
        encoded |= (head[3] as usize) << 24;
    }
    encoded >> 2
}

fn read_len<R: Read>(reader: &mut R) -> io::Result<usize> {
    Ok(read_len_with_header(reader)?.len)
}

fn header_hex(head: &[u8; 4], head_len: usize) -> String {
    head[..head_len]
        .iter()
        .map(|byte| format!("{:02X}", byte))
        .collect::<Vec<_>>()
        .join(" ")
}

fn header_ascii(head: &[u8; 4], head_len: usize) -> String {
    head[..head_len]
        .iter()
        .map(|byte| {
            if (0x20..=0x7e).contains(byte) {
                *byte as char
            } else {
                '.'
            }
        })
        .collect()
}

fn write_len<W: Write>(writer: &mut W, len: usize) -> io::Result<()> {
    if len <= 0x3F {
        writer.write_all(&[(len << 2) as u8])
    } else if len <= 0x3FFF {
        let head = ((len << 2) as u16 | 0x01).to_le_bytes();
        writer.write_all(&head)
    } else if len <= 0x3FFFFF {
        let head = (len << 2) as u32 | 0x02;
        writer.write_all(&[
            (head & 0xFF) as u8,
            ((head >> 8) & 0xFF) as u8,
            ((head >> 16) & 0xFF) as u8,
        ])
    } else if len <= 0x3FFFFFFF {
        let head = ((len << 2) as u32 | 0x03).to_le_bytes();
        writer.write_all(&head)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "frame length overflow",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Write};
    use std::net::TcpListener;
    use std::thread;

    fn encode_len(len: usize) -> Vec<u8> {
        let mut out = Cursor::new(Vec::new());
        write_len(&mut out, len).unwrap();
        out.into_inner()
    }

    fn decode_len(bytes: &[u8]) -> usize {
        let mut cursor = Cursor::new(bytes.to_vec());
        read_len(&mut cursor).unwrap()
    }

    #[test]
    fn encodes_upstream_variable_headers() {
        assert_eq!(encode_len(0x3F), vec![0xFC]);
        assert_eq!(encode_len(0x40), vec![0x01, 0x01]);
        assert_eq!(encode_len(0x3FFF), vec![0xFD, 0xFF]);
        assert_eq!(encode_len(0x4000), vec![0x02, 0x00, 0x01]);
    }

    #[test]
    fn decodes_upstream_variable_headers() {
        assert_eq!(decode_len(&[0xFC]), 0x3F);
        assert_eq!(decode_len(&[0x01, 0x01]), 0x40);
        assert_eq!(decode_len(&[0xFD, 0xFF]), 0x3FFF);
        assert_eq!(decode_len(&[0x02, 0x00, 0x01]), 0x4000);
        assert_eq!(decode_len(&[0xD5, 0x08]), 565);
    }

    fn loopback_pair() -> Option<(TcpListener, TcpStream)> {
        let listener = match TcpListener::bind("127.0.0.1:0") {
            Ok(listener) => listener,
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return None,
            Err(error) => panic!("loopback listener bind failed: {error}"),
        };
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        Some((listener, client))
    }

    #[test]
    fn cancellable_frame_read_keeps_partial_payload_across_poll_timeouts() {
        let Some((listener, mut client)) = loopback_pair() else {
            return;
        };
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(&[20, b'h', b'e']).unwrap();
            thread::sleep(Duration::from_millis(250));
            stream.write_all(b"llo").unwrap();
        });

        let payload =
            read_frame_cancellable(&mut client, Instant::now() + Duration::from_secs(1), || {
                false
            })
            .unwrap();
        assert_eq!(payload, b"hello");
        server.join().unwrap();
    }

    #[test]
    fn partial_frame_deadline_is_not_retriable_as_an_empty_timeout() {
        let Some((listener, mut client)) = loopback_pair() else {
            return;
        };
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream.write_all(&[20, b'h']).unwrap();
            thread::sleep(Duration::from_millis(250));
        });

        let error = read_frame_cancellable(
            &mut client,
            Instant::now() + Duration::from_millis(80),
            || false,
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("partial frame"));
        server.join().unwrap();
    }
}
