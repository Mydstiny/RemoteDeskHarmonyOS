# 远程 AI：鸿蒙客户端与 Pro 一体化实施

日期：2026-09-08。用户已授权继续实施 AI4，要求 FAB、新增主机、经典/全新编辑、弹窗、数据管理、专属设置、会话控制与既有协议风格一致。以[总计划](2026-09-07-pro-remote-ai-workspace.md)及[固定宿主合同](2026-09-08-remote-ai-native-host-handoff.md)为基础；代码侧验收和设备验收分别记录如下。

## 实施顺序

1. 安全连接与数据：严格私有 CA/SAN、TLS 1.3、设备独立密钥/CSR、一次邀请和 mTLS；独立加密本地 RDB、账号/generation 防线、请求落盘与原回执恢复。证书和密钥不进入普通主机字段、导出、云同步或日志。
2. 统一主机体验：FAB 协议选项“远程 AI · Pro”，Codex/DSH 后端选择；经典表单与全新流程复用同一校验和保存服务。投影到既有主机卡片/分组/排序/搜索，新增、编辑、删除与连接均正确分派，不进入普通桌面协议 native 会话。
3. 会话工作台：项目/会话、模型与设置、流式文本/执行卡片、审批和完整差异、结构化提问、分页/断线恢复、单写者租约、取消、改名/归档/分叉/压缩、附件与受管理终端。两种后端按能力展示，不把接受请求当完成。
4. Pro 与专属设置：登记 workspace/codex/dsh；共享 ProRuntime 做显示与业务操作检查。独立监听账号转换、按账号隔离配置；明确撤权阻止新增提示和批准，提供受限停止/断开。设置含安装提示词、服务/配对状态、显示/恢复偏好、本机数据清理和诊断。
5. 集成与验证：Phone/Pad/PC 风格、键盘与前后台；真实设备 TLS/配对与两个真实模型最小闭环，再做双设备 LAN/断网/撤权/租约与恢复矩阵。定向测试、当次两项 Hvigor、Light、独立复核和分步提交。

## 架构与协作约束

- 使用 `services/ai`、`components/ai` 和独立会话页；HostListPage 仅定点接线，复用 Theme、协议图标、AppSheetHeader 及现有 Sheet 关闭/切换规则。
- ProAppRuntime.runtime.decision/subscribe 为权益权威；同时验证 AccountSessionCoordinator 的 transition、ownerScopeId、generation 与 sessionState。Debug Pro 不替代账号/设备授权；已实现增量 experimental，未实现 RustDesk 传输 planned。
- 账号切换关闭旧控制通道并丢弃内存凭据；撤权不删除配置、历史或无条件杀远端任务。设备撤销按宿主协议立即失效。
- 数据保留在本机加密库，主机 UI 只持有脱敏投影；不复用同步表保存 AI 密钥，不改变现有免费协议功能及其 E2EE 规则。
- 连接参数区分逻辑服务身份与网络拨号地址，为后续 RustDesk PortForward 保留 transport 接口；本轮不把尚未实现的中继作为可用选项。
- 保留并行 Pro 与文件传输修改，共享字段精确修改。用户允许多编译任务直接执行；若实际产物冲突，修复并重跑失败项。

## 当前状态

实现已接入应用，保留当前 Pro 活动分支。Native、服务/数据、页面生命周期均已分别复核；主列表分派增量复核亦 PASS。AI 分类中改选 RDP 的路由问题已修复并加实际回调回归。代码构建通过不代表真机验收。

- 安全通道使用已有 OpenSSL 的独立上下文：私有 CA、严格 SAN、TLS 1.3、客户端证书与密钥匹配；异步 NAPI 请求有取消、超时、环境退出清理。DNS 解析后只拨号数字地址；发出请求后的失败不自动重试写操作。
- AI 主机、配对身份、偏好和操作回执置于独立加密 RDB。账号/恢复 epoch、主机 revision、受限撤权清理和单写者租约已接入。配置导出仅含白名单元数据，导入新增未配对主机；秘密与会话正文不进入配置备份。
- FAB/经典和全新添加编辑、主机卡片/协议分组/搜索/排序/批量删除、专属设置页已接线。编辑器支持后端、地址、证书名称、端口、名称与分组；两种样式共享保存和配对校验。
- 工作区包含项目/会话、模型与推理强度、流式记录、分页、审批/提问、差异、受管理终端、操作核对、附件、取消/改名/归档/恢复/分叉/压缩。后台断开与前台恢复读取受偏好和账号边界约束；重新取得控制权为显式动作。
- Pro workspace/codex/dsh 登记为 experimental；RustDesk transport 仍为 planned，当前只开放 LAN 实验连接。购买权益与生产开放仍受统一 ProRuntime 控制。

## 当前验证

- Native：29 项实际 TLS/NAPI 测试 PASS（真实 OpenSSL/TLS fixtures，非 HarmonyOS 设备）。
- ArkTS 生产方法与 SQL：账户/竞争 6、恢复 5、工作区 10、导入 3、最终边界 6，合计 30 项 PASS；SQL 裁剪通过实际内存 SQLite 验证，非 HarmonyOS RDB 故障矩阵。
- UI：实际页面方法 6 项 PASS；现有主机分组测试 8 项、实际入口回调/策略 3 组 PASS。未模拟 ArkUI 渲染。
- 当次门禁：default@OhosTestCompileArkTS BUILD SUCCESSFUL in 9 s 708 ms；签名 assembleHap BUILD SUCCESSFUL in 1 min 7 s 352 ms，含 SignHap，均 exit 0；Light 和 diff PASS。
- 可重复脚本：scripts/tests/test_ai_native_tls.mjs；test_ai_races.cjs、test_ai_restore.cjs、test_ai_workspace.cjs、test_ai_import.cjs、test_ai_final_boundaries.cjs、test_ai_ui_lifecycle.cjs、test_ai_host_groups.cjs、test_ai_entries.cjs。ArkTS 脚本使用 AI_TYPESCRIPT_PATH 指向安装的 TypeScript；最后边界脚本需支持 node:sqlite 的 Node。

## 尚需验收

真实 HarmonyOS 设备配对/mTLS、两个真实模型的客户端闭环、LAN 双设备租约/断网/撤权/恢复、Phone/Pad/PC 布局/键盘/前后台矩阵均 NOT RUN。宿主 v0.3.0 既有实测不替代新客户端验收。未部署或替换用户正在使用的手机应用；同分支 Pro/文件传输仍有活动工作，不合并整个分支。本地完成回执裁剪限制为 200 条及 8 MiB 请求 body，并非数据库总字节配额。
