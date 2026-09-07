# 架构地图

核验快照：2026-09-07，`0000d4ca4`。路径表示当前实现入口，不表示每项能力已完成设备验收。

## 从用户动作到执行

| 层 | 入口 | 核对内容 |
|---|---|---|
| 主机/设置 | [HostListPage.ets](../../../../entry/src/main/ets/pages/HostListPage.ets) | 添加、发现、连接前认证、设置 sheet、协议入口 |
| 远程桌面 | [RemoteDesktop.ets](../../../../entry/src/main/ets/pages/RemoteDesktop.ets) | RDP/RustDesk/VNC 会话、输入、工具栏与窗口状态 |
| SSH 工作台 | [SshTerminal.ets](../../../../entry/src/main/ets/pages/SshTerminal.ets) | terminal、SFTP、tabs、转发和操作面板 |
| Moonlight | [MoonlightStreamPage.ets](../../../../entry/src/main/ets/pages/MoonlightStreamPage.ets)、[MoonlightAppCatalogPage.ets](../../../../entry/src/main/ets/pages/MoonlightAppCatalogPage.ets) | 应用目录、launch、stream、恢复 |
| ArkTS 门面 | [ExtensionLoader.ets](../../../../entry/src/main/ets/services/ExtensionLoader.ets)、[rdpnapi.d.ts](../../../../entry/src/main/ets/types/rdpnapi.d.ts) | 配置序列化、native handle、事件、断开回执 |
| NAPI/会话 | [extension_loader_napi.cpp](../../../../entry/src/main/cpp/extensions/extension_loader_napi.cpp)、[session_registry.h](../../../../entry/src/main/cpp/extensions/session_registry.h) | owner、代次、协议 adapter、异步 teardown |
| 原生协议 | [rdp](../../../../entry/src/main/cpp/rdp)、[rustdesk](../../../../entry/src/main/cpp/rustdesk)、[ssh](../../../../entry/src/main/cpp/ssh)、[vnc](../../../../entry/src/main/cpp/vnc) | 状态机、I/O、认证、队列和资源归属 |
| Rust 实现 | [lib.rs](../../../../rustdesk_ffi/src/lib.rs)、[connector.rs](../../../../rustdesk_ffi/src/connector.rs)、[terminal_core](../../../../rustdesk_ffi/src/terminal_core) | FFI 契约、RustDesk 协商/流、终端核心 |
| 媒体/输入 | [render](../../../../entry/src/main/cpp/render)、[input](../../../../entry/src/main/cpp/input)、[moonlight](../../../../entry/src/main/cpp/moonlight) | decoder、GL、坐标变换、媒体/手柄 |
| 存储与账号 | [CloudStore.ets](../../../../entry/src/main/ets/services/CloudStore.ets)、[AccountSessionCoordinator.ets](../../../../entry/src/main/ets/services/AccountSessionCoordinator.ets) | owner scope、迁移、cloud admission、切换与清理 |

## 跨模块所有权

先确认资源的 owner、创建时机、终止条件、异步回调归属、释放证明。会话 ID 不能替代整个生命周期身份。

- 应用会话：[ActiveRemoteSessionRegistry.ets](../../../../entry/src/main/ets/services/ActiveRemoteSessionRegistry.ets)。
- 窗口：[RemoteSessionWindowCoordinator.ets](../../../../entry/src/main/ets/services/RemoteSessionWindowCoordinator.ets)、[RemoteSessionWindowAuthorization.ets](../../../../entry/src/main/ets/services/RemoteSessionWindowAuthorization.ets)。
- 转场/退出：[RemoteSessionTransitionGate.ets](../../../../entry/src/main/ets/services/RemoteSessionTransitionGate.ets)、[RemoteSessionTerminationPolicy.ets](../../../../entry/src/main/ets/services/RemoteSessionTerminationPolicy.ets)、[session_teardown_executor.cpp](../../../../entry/src/main/cpp/extensions/session_teardown_executor.cpp)。
- PIP：[RemoteSessionPipLifecyclePolicy.ets](../../../../entry/src/main/ets/services/RemoteSessionPipLifecyclePolicy.ets)。
- 数据作用域：[AccountScopePolicy.ets](../../../../entry/src/main/ets/services/AccountScopePolicy.ets)、[PlatformCloudIdentityPolicy.ets](../../../../entry/src/main/ets/services/PlatformCloudIdentityPolicy.ets)。

## 新功能接入

先确定是否已有共享 policy/service。UI 展示、策略决定与原生副作用各自落在现有边界；小修复不强制重构。

新增设置追踪默认值、读取失败、持久化、旧值兼容、全部连接入口和 native 消费；可用性开关必须与真实能力一致。Moonlight 有独立模型/目录/媒体链，不能只改四协议 picker 就宣称接入完成。

修改数据字段同时查保存、查询、同步、迁移、备份、删除和导入，不只查当前表单。测试从 `entry/src/test` 和 `entry/src/main/cpp/test` 查对应 policy。

## 架构历史的使用边界

[TECH_SPEC.md](../../../../docs/TECH_SPEC.md) 是早期“双协议”设计；[RDP_STATUS.md](../../../../docs/RDP_STATUS.md) 和各协议计划提供演进线索。先读对应专题和当前代码，不能将早期目录图或设计目标当成现在的完整架构。
