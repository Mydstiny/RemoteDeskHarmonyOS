# SSH / SFTP / 终端工作台

核验快照：2026-09-07，`0000d4ca4`。终端、SFTP、跳板与转发复用传输基础，但每个 operation 的 owner 和取消必须单独核对。

## 入口

| 功能 | 文件 |
|---|---|
| 工作台 UI | [SshTerminal.ets](../../../../../entry/src/main/ets/pages/SshTerminal.ets)、[ssh](../../../../../entry/src/main/ets/services/ssh) |
| 预检/信任 | [SshPreflightService.ets](../../../../../entry/src/main/ets/services/SshPreflightService.ets)、[SshHostKeyTrustPolicy.ets](../../../../../entry/src/main/ets/services/SshHostKeyTrustPolicy.ets) |
| 操作配置与秘密 | [SshOperationConfigPolicy.ets](../../../../../entry/src/main/ets/services/SshOperationConfigPolicy.ets)、[SshOperationRouteSecretService.ets](../../../../../entry/src/main/ets/services/SshOperationRouteSecretService.ets) |
| native session | [ssh_adapter.cpp](../../../../../entry/src/main/cpp/ssh/ssh_adapter.cpp)、[ssh_libssh2_session.h](../../../../../entry/src/main/cpp/ssh/ssh_libssh2_session.h) |
| 独立 operation | [ssh_operation_executor.cpp](../../../../../entry/src/main/cpp/ssh/ssh_operation_executor.cpp)、[ssh_operation_transport.h](../../../../../entry/src/main/cpp/ssh/ssh_operation_transport.h)、[ssh_operation_control.h](../../../../../entry/src/main/cpp/ssh/ssh_operation_control.h) |
| 转发 | [ssh_forward_target_connector.cpp](../../../../../entry/src/main/cpp/ssh/ssh_forward_target_connector.cpp)、[SshForwardingProfileStore.ets](../../../../../entry/src/main/ets/services/SshForwardingProfileStore.ets) |
| 终端核心/渲染 | [terminal_core](../../../../../rustdesk_ffi/src/terminal_core)、[ssh_terminal_renderer.cpp](../../../../../entry/src/main/cpp/terminal/ssh_terminal_renderer.cpp)、[SshTerminalRendererBridge.ets](../../../../../entry/src/main/ets/napi/SshTerminalRendererBridge.ets) |

## 连接、认证、I/O

排查直连 → proxy → jump 1–3 → target，每跳信任和凭据绑定对应身份，不能只校验最终 target。DNS/IPv6、TLS/代理错误、SSH 握手、认证、channel 和 SFTP 阶段分别归类。

所有 libssh2 调用面检查 session serialization、network generation admission 和取消：握手、交互认证、read/write、window resize、SFTP、forwarding、teardown。不能只给 connect 加 fence。

交互认证 prompt/response 要核对 owner 和当前请求；响应秘密释放前擦除。延期 teardown 不能用无法 join 的无限线程。来源：[ssh_keyboard_interactive_route_admission.h](../../../../../entry/src/main/cpp/ssh/ssh_keyboard_interactive_route_admission.h)、[ssh_sensitive_buffer.h](../../../../../entry/src/main/cpp/ssh/ssh_sensitive_buffer.h)、[ssh_route_teardown_policy.h](../../../../../entry/src/main/cpp/ssh/ssh_route_teardown_policy.h)。

## 终端与文件操作

- 输入已入队和 PTY 已收到是不同状态；搜索、选择、复制、IME 与发送键序列各自测试。
- resize 比较本地 surface、字符网格和远端 PTY，避免 UI 尺寸改变但远端行列仍旧。
- 2026-09 常用命令修复只将选中内容插入终端，不自动执行；不要把“保留存储顺序”写成用户排序功能。
- SFTP cancel/retry、临时目标、partial progress、完整性和 overwrite/rename/delete 语义分开。远端破坏性操作按用户具体授权执行，skill 不额外授权。
- API 26 是当前开发基准；工作台具体组件仍依据文档、platform probe 与实现逐项核验，不把未启用声明写成支持。

## 验证

[SSH_TERMINAL_TEST_CASES.md](../../../../../docs/SSH_TERMINAL_TEST_CASES.md)、[SshPreflightService.test.ets](../../../../../entry/src/test/SshPreflightService.test.ets)、[SshOperationConfigPolicy.test.ets](../../../../../entry/src/test/SshOperationConfigPolicy.test.ets)、[ssh_route_call_surface_contract_test.cpp](../../../../../entry/src/main/cpp/test/ssh_route_call_surface_contract_test.cpp)、[ssh_adapter_runtime_test.cpp](../../../../../entry/src/main/cpp/test/ssh_adapter_runtime_test.cpp)。

需要实际 server 时只用已授权受控端点/fixture；不自动运行保存的生产命令。验证直连和代理/跳板/转发、断网/切网、认证取消与关闭期间 I/O。

历史：[2026-08-08-ssh-level-b-frp-completion-plan.md](../../../../../docs/codex/plans/2026-08-08-ssh-level-b-frp-completion-plan.md)、[2026-08-19-ssh-workbench-execution-ledger.md](../../../../../docs/codex/plans/2026-08-19-ssh-workbench-execution-ledger.md)。旧 `SSH_TERMINAL_CLAUDECODE_HANDOFF.md` 是历史材料，不作为当前代理流程。
