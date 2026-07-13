// build.rs — 编译 RustDesk protobuf 协议定义 → Rust 代码
//
// 使用 protobuf-codegen-pure (纯 Rust 实现，无需 protoc 二进制)
// 从 hbb_common/protos/ 提取核心消息定义并生成到 OUT_DIR
//
// protobuf-codegen-pure 2.x 生成的代码包含 #![allow(...)] 内层属性，
// 这些属性只能在 crate root 使用。当 include!() 在子模块中时，
// 需要转换为外层属性 #[allow(...)]。

use protobuf_codegen_pure::Codegen;
use std::env;
use std::fs;
use std::path::Path;

fn main() {
    let proto_dir = Path::new("../rustdesk_vendor/libs/hbb_common/protos");
    let out_dir = env::var("OUT_DIR").unwrap();
    let out_path = Path::new(&out_dir);

    // 核心 protobuf 消息定义
    let proto_files = &[
        proto_dir.join("message.proto"),
        proto_dir.join("rendezvous.proto"),
    ];

    // 验证所有 proto 文件存在
    for f in proto_files {
        if !f.exists() {
            panic!("proto file not found: {}", f.display());
        }
        println!("cargo:warning=Compiling proto: {}", f.display());
    }

    // 生成 Rust 代码
    Codegen::new()
        .out_dir(out_path)
        .inputs(proto_files)
        .include(proto_dir)
        .run()
        .expect("protobuf codegen failed");

    // 后处理: 将 #![...] 转换为 #[...], //! 转换为 ///
    // 这样生成的代码可以被 include!() 在任何模块中使用
    for f in proto_files {
        let stem = f.file_stem().unwrap().to_str().unwrap();
        let gen_file = out_path.join(format!("{}.rs", stem));
        let content = fs::read_to_string(&gen_file)
            .expect(&format!("failed to read generated {}", gen_file.display()));

        let fixed: String = content
            .lines()
            .map(|line| {
                if line.starts_with("#![") {
                    // #![allow(...)] → #[allow(...)]
                    line.replacen("#![", "#[", 1)
                } else if line.starts_with("//!") {
                    // //! doc comment → /// doc comment
                    line.replacen("//!", "///", 1)
                } else {
                    line.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n");

        fs::write(&gen_file, fixed)
            .expect(&format!("failed to write fixed {}", gen_file.display()));
        println!(
            "cargo:warning=Fixed inner attributes in: {}",
            gen_file.display()
        );
    }

    // 通知 cargo 当 proto 文件变化时重新运行 build.rs
    println!("cargo:rerun-if-changed=build.rs");
    for f in proto_files {
        println!("cargo:rerun-if-changed={}", f.display());
    }

    // === Opus 链接配置 ===
    let target = env::var("TARGET").unwrap_or_default();
    if target.contains("ohos") {
        // 查找 libopus 路径
        let opus_dir = if let Ok(dir) = env::var("OPUS_LIB_DIR") {
            std::path::PathBuf::from(dir)
        } else if let Ok(vcpkg) = env::var("VCPKG_ROOT") {
            let arch = if target.contains("aarch64") {
                "arm64"
            } else {
                "x64"
            };
            std::path::PathBuf::from(&vcpkg)
                .join("installed")
                .join(format!("{}-linux", arch))
                .join("lib")
        } else {
            let abi = if target.contains("aarch64") {
                "arm64-v8a"
            } else {
                "x86_64"
            };
            let project =
                std::path::PathBuf::from(&env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
            project.join("../build/opus-ohos/libs").join(abi)
        };
        println!("cargo:rustc-link-search=native={}", opus_dir.display());
        println!("cargo:rustc-link-lib=static=opus");
        println!("cargo:warning=opus: link-search={}", opus_dir.display());
        println!("cargo:rerun-if-env-changed=OPUS_LIB_DIR");
        println!("cargo:rerun-if-env-changed=VCPKG_ROOT");
    }
}
