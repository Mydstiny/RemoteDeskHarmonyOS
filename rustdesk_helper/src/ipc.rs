//! IPC 帧解析/分发模块
//!
//! 帧格式 (匹配 C++ 侧 rustdesk_ipc.h):
//!   [4 bytes payload_size (u32 LE)] [1 byte msg_type] [N bytes payload]
//!
//! 消息类型定义见 entry/src/main/cpp/rustdesk/rustdesk_ipc.h

#![cfg(unix)]

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

const MAX_FRAME_SIZE: usize = 4 * 1024 * 1024; // 4 MB

pub fn handle_client(mut stream: UnixStream) -> std::io::Result<()> {
    let mut header = [0u8; 5];
    let mut payload_buf = Vec::with_capacity(64 * 1024);

    loop {
        // 读取 5 字节帧头
        if stream.read_exact(&mut header).is_err() {
            break; // 客户端断开
        }

        let payload_size = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
        let msg_type = header[4];

        if payload_size as usize > MAX_FRAME_SIZE - 5 {
            eprintln!("[ipc] frame too large: {} bytes", payload_size);
            break;
        }

        // 读取 payload
        payload_buf.resize(payload_size as usize, 0);
        if stream.read_exact(&mut payload_buf).is_err() {
            break;
        }

        // 处理消息 — 返回响应 (如果需要)
        match msg_type {
            0x01 => handle_connect(&mut stream, &payload_buf)?,   // RD_IPC_CONNECT_REQ
            0x03 => handle_disconnect(),                            // RD_IPC_DISCONNECT
            0x10 => handle_key_event(&payload_buf),                // RD_IPC_INPUT_KEY
            0x11 => handle_mouse_event(&payload_buf),              // RD_IPC_INPUT_MOUSE
            0x12 => handle_wheel_event(&payload_buf),              // RD_IPC_INPUT_WHEEL
            0x13 => {} // RD_IPC_INPUT_TEXT — TODO
            0xFE => {
                // PING → PONG
                let pong: [u8; 6] = [1, 0, 0, 0, 0xFF, 0];
                stream.write_all(&pong)?;
            }
            _ => {
                eprintln!("[ipc] unknown msg_type: 0x{:02X}", msg_type);
            }
        }
    }

    println!("[ipc] client disconnected");
    Ok(())
}

fn read_u32(payload: &[u8], offset: usize) -> u32 {
    if payload.len() < offset + 4 {
        return 0;
    }
    u32::from_le_bytes([
        payload[offset],
        payload[offset + 1],
        payload[offset + 2],
        payload[offset + 3],
    ])
}

fn read_cstr(payload: &[u8], offset: usize, len: usize) -> String {
    if payload.len() <= offset {
        return String::new();
    }
    let end = (offset + len).min(payload.len());
    String::from_utf8_lossy(&payload[offset..end])
        .trim_end_matches('\0')
        .to_string()
}

fn handle_connect(stream: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    // 解析 RdIpcConnectReq, 密码正文只转交给 core, 不写日志。
    if payload.len() < 260 {
        let err: [u8; 6] = [1, 0, 0, 0, 0x02, 0x01]; // ACK + error=1
        return stream.write_all(&err).map(|_| ());
    }

    let host = read_cstr(payload, 0, 256);
    let port = read_u32(payload, 256);
    let peer_id = read_cstr(payload, 260, 128);
    let password_len = read_u32(payload, 516);
    let width = read_u32(payload, 520);
    let height = read_u32(payload, 524);
    let codec = read_u32(payload, 528);
    let image_quality = read_u32(payload, 532);
    let direct_ip = read_u32(payload, 536) != 0;
    let direct_port = read_u32(payload, 540);
    let lan_discovery = read_u32(payload, 544) != 0;
    let privacy_mode = read_u32(payload, 548) != 0;
    let password_mode = read_u32(payload, 552);
    let password_length = read_u32(payload, 556);
    let relay_id = read_cstr(payload, 560, 128);
    let account_id = read_cstr(payload, 688, 128);

    println!(
        "[ipc] CONNECT_REQ: host={} port={} peer={} size={}x{} codec={} quality={} direct={} directPort={} lan={} privacy={} pwdMode={} pwdLen={} secretBytes={} relay={} account={}",
        host,
        port,
        peer_id,
        width,
        height,
        codec,
        image_quality,
        direct_ip,
        direct_port,
        lan_discovery,
        privacy_mode,
        password_mode,
        password_length,
        password_len,
        relay_id,
        account_id
    );

    // TODO: 调用 RustDesk core 建立连接
    // let config = RustDeskConfig { ... };
    // rustdesk_connect(config);

    // 回复 ACK (成功)
    let ack: [u8; 6] = [1, 0, 0, 0, 0x02, 0x00]; // RD_IPC_CONNECT_ACK + status=0
    stream.write_all(&ack)?;
    Ok(())
}

fn handle_disconnect() {
    println!("[ipc] DISCONNECT");
    // TODO: rustdesk_disconnect()
}

fn handle_key_event(payload: &[u8]) {
    if payload.len() >= 5 {
        let scancode = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
        let pressed = payload[4] != 0;
        println!("[ipc] KEY: sc={} p={}", scancode, pressed);
        // TODO: rustdesk_input_key(scancode, pressed)
    }
}

fn handle_mouse_event(payload: &[u8]) {
    if payload.len() >= 6 {
        let x = u16::from_le_bytes([payload[0], payload[1]]);
        let y = u16::from_le_bytes([payload[2], payload[3]]);
        let button = payload[4];
        let pressed = payload[5] != 0;
        println!("[ipc] MOUSE: ({},{}) btn={} p={}", x, y, button, pressed);
        // TODO: rustdesk_input_mouse(x, y, button, pressed)
    }
}

fn handle_wheel_event(payload: &[u8]) {
    if payload.len() >= 8 {
        let delta = i32::from_le_bytes([payload[4], payload[5], payload[6], payload[7]]);
        println!("[ipc] WHEEL: delta={}", delta);
        // TODO: rustdesk_input_wheel(delta)
    }
}
