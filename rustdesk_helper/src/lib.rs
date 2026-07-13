//! rustdesk_helper — IPC 服务端 (编译为 cdylib)
//!
//! dlopen → run_helper(socket_path) 在独立线程中运行 Unix Domain Socket listener
//! AGPL-3.0 许可证

mod ipc;

use std::ffi::CStr;
use std::os::raw::c_char;

#[cfg(unix)]
fn helper_main(socket_path: &str) -> std::io::Result<()> {
    use std::os::unix::net::UnixListener;
    use std::path::Path;

    println!("[rustdesk_helper] starting IPC server on {}", socket_path);

    let path = Path::new(socket_path);
    if path.exists() {
        std::fs::remove_file(path)?;
    }

    let listener = UnixListener::bind(socket_path)?;
    println!("[rustdesk_helper] listening...");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                println!("[rustdesk_helper] client connected");
                if let Err(e) = ipc::handle_client(stream) {
                    eprintln!("[rustdesk_helper] client error: {}", e);
                }
            }
            Err(e) => {
                eprintln!("[rustdesk_helper] accept error: {}", e);
            }
        }
    }

    Ok(())
}

/// C ABI: 在独立线程中启动 IPC 服务端
/// dlopen 此 .so 后调用此函数, socket_path 为 Unix Domain Socket 路径
#[no_mangle]
pub extern "C" fn run_helper(socket_path: *const c_char) -> i32 {
    if socket_path.is_null() {
        return -1;
    }
    let path = unsafe {
        match CStr::from_ptr(socket_path).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return -2,
        }
    };
    println!("[rustdesk_helper] run_helper called with path={}", path);
    match helper_main(&path) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("[rustdesk_helper] helper_main error: {}", e);
            -3
        }
    }
}

#[cfg(not(unix))]
#[no_mangle]
pub extern "C" fn run_helper(_socket_path: *const c_char) -> i32 {
    -99
}
