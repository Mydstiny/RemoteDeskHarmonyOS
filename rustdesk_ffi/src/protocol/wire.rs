// wire.rs — RustDesk TCP 帧协议
//
// RustDesk upstream 使用 hbb_common::BytesCodec:
//   头部低 2 位表示头部长度 (1-4 bytes)，其余位表示 payload 长度。
//   payload 是 protobuf 序列化后的消息体。
use std::io::{self, Read, Write};
use std::net::TcpStream;

/// TCP 帧最大大小 (16MB，覆盖常见视频帧)
pub const MAX_FRAME_SIZE: usize = 16 * 1024 * 1024;

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

    let mut n = head[0] as usize;
    if head_len > 1 {
        n |= (head[1] as usize) << 8;
    }
    if head_len > 2 {
        n |= (head[2] as usize) << 16;
    }
    if head_len > 3 {
        n |= (head[3] as usize) << 24;
    }

    Ok(FrameHeader {
        len: n >> 2,
        head_len,
        head,
    })
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
    use std::io::Cursor;

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
}
