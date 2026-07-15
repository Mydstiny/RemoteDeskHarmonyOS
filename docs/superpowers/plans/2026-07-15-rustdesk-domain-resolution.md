# RustDesk Domain Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix RustDesk FFI connections so ID/Rendezvous, Relay, direct, and file-transfer paths support DNS hostnames without changing protocol authentication or API behavior.

**Architecture:** Add one focused TCP endpoint helper around `ToSocketAddrs` and a shared deadline. Replace the three direct `SocketAddr` parsing sites with the helper, while retaining protocol-specific framing and state transitions in their current modules.

**Tech Stack:** Rust 2021, `std::net::ToSocketAddrs`, `TcpStream`, existing `cargo test` unit-test layout, HarmonyOS HAP/native build scripts.

## Global Constraints

- Work only in `C:\Users\14288\DevEcoStudioProjects\RemoteDesktop`.
- Do not create a persistent Git worktree.
- Do not modify API configuration semantics; blank API remains valid for ordinary connections.
- Do not log passwords, public/private server keys, tokens, or API credentials.
- Preserve the existing 10-second TCP connect budget and current protocol state machine.
- Run tests before claiming completion.

### Task 1: Add failing endpoint regression tests

**Files:**
- Modify: `rustdesk_ffi/src/protocol/rendezvous.rs:653-end`
- Modify: `rustdesk_ffi/src/connector.rs:2050-end`

**Interfaces:**
- Consume: existing `RendezvousClient::connect`, `RendezvousClient::create_relay`, and `RustDeskConnector::connect_direct`.
- Produce: failing tests that demonstrate hostname endpoints are rejected by the current implementation.

- [x] **Step 1: Write tests using local listeners and hostname endpoints.**

  Add tests that bind `127.0.0.1:0`, call the existing connection paths with `localhost`, and assert the connection succeeds or reaches the listener. Add an invalid `https://localhost` test that expects `InvalidInput`.

- [x] **Step 2: Run the focused tests and verify the failure is the current hostname parse error.**

  Run:

  ```powershell
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features hostname -- --nocapture
  ```

  Expected: failure before any protocol frame is processed because `localhost:<port>` is parsed as a `SocketAddr`.

### Task 2: Implement shared DNS-capable TCP connection helper

**Files:**
- Create: `rustdesk_ffi/src/net.rs`
- Modify: `rustdesk_ffi/src/lib.rs:23-30`

**Interfaces:**
- Consumes: host/port endpoint strings and a stage label.
- Produces: `connect_tcp_endpoint(endpoint: &str, default_port: u16, stage: &str, timeout: Duration) -> io::Result<TcpStream>`.

- [x] **Step 1: Add the helper with strict endpoint validation and `ToSocketAddrs`.**

  The helper must reject empty values and URI schemes, parse a supplied port when present, resolve `(host, port)` through `ToSocketAddrs`, try each candidate until one connects or the shared deadline expires, and return errors containing `stage`, masked endpoint text, and the underlying error kind.

- [x] **Step 2: Run the focused tests and verify they still fail only at unintegrated call sites.**

  Run:

  ```powershell
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features net -- --nocapture
  ```

  Expected: helper unit tests pass; integration tests remain red until existing call sites use the helper.

### Task 3: Integrate the helper into every RustDesk TCP endpoint

**Files:**
- Modify: `rustdesk_ffi/src/protocol/rendezvous.rs:58-80`
- Modify: `rustdesk_ffi/src/protocol/rendezvous.rs:328-344`
- Modify: `rustdesk_ffi/src/connector.rs:234-256`

**Interfaces:**
- Consume: `net::connect_tcp_endpoint`.
- Produce: hostname-aware Rendezvous, Relay, direct, and file-transfer connections with stage-specific errors.

- [x] **Step 1: Replace `RendezvousClient::connect` direct parsing with the helper.**

  Call `connect_tcp_endpoint(&format!("{}:{}", host, port), port, "rendezvous", Duration::from_secs(10))`, or pass host and port through a helper overload that avoids double parsing. Preserve read/write timeout setup and secure handshake behavior.

- [x] **Step 2: Replace `create_relay` direct parsing with the helper.**

  Pass the Relay response endpoint and default port `21117`; preserve the existing relay frame write and timeout setup.

- [x] **Step 3: Replace `connect_direct` direct parsing with the helper.**

  Pass the configured direct host and port with stage `direct`; preserve the existing peer public-key and login protocol.

- [x] **Step 4: Run the focused regression tests and verify all hostname paths are green.**

  Run:

  ```powershell
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features net -- --nocapture
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features rendezvous_ -- --nocapture
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features relay_connect_accepts_hostname_endpoint_with_explicit_port -- --nocapture
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features direct_connect_resolves_hostname_before_peer_handshake -- --nocapture
  ```

  Expected: all focused tests pass.

### Task 4: Run full verification and update project memory

**Files:**
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\CURRENT.md`
- Modify: `C:\Users\14288\.codex\projects\C--Users-14288\memory\QUEUE.md`

**Interfaces:**
- Consume: completed code and test results.
- Produce: evidence-backed checkpoint with exact command results and remaining real-device acceptance.

- [x] **Step 1: Run the full Rust test suite.**

  ```powershell
  cargo test --manifest-path rustdesk_ffi/Cargo.toml --no-default-features --quiet
  ```

- [x] **Step 2: Run project native/ArkTS/HAP/Light gates according to `CURRENT.md`.**

  Record exact exit codes and failure counts; do not claim a gate passed from partial output.

- [x] **Step 3: Run `git diff --check` and inspect the final diff.**

- [x] **Step 4: Update memory with completed verification and remaining real-device hostname acceptance.**

- [x] **Step 5: Commit only the RustDesk fix, tests, and design/plan records.**
