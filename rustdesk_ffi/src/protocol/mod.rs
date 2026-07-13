// protocol/mod.rs — RustDesk 协议层
//
// 每个 .proto 文件生成到独立的子模块中，避免 file_descriptor_proto 等
// 生成符号的命名冲突。

// message.proto → message_proto 子模块
pub mod message_proto {
    include!(concat!(env!("OUT_DIR"), "/message.rs"));
}

// rendezvous.proto → rendezvous_proto 子模块
pub mod rendezvous_proto {
    include!(concat!(env!("OUT_DIR"), "/rendezvous.rs"));
}

pub mod rendezvous;
pub mod session;
pub mod wire;
