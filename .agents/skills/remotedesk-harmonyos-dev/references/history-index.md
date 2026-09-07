# 开发历史入口

## 已覆盖范围与证据等级

本索引于 2026-09-07 整理，公开 main 快照 `8edc18786`，本次已授权活动分支源码快照 `0000d4ca4`。

- 公开 Git 主线：从 `a97c2ebdd`（2026-07-13 开源基线）到 `8edc18786`，共 51 个 first-parent 节点，完整节点表见 [public-timeline.md](public-timeline.md)。这是主线索引，内部实现提交按路径继续查询。
- 公开基线之前：由仓库现存六月/七月设计、计划和报告提供线索；这些文件可能后来才入库，文件名日期不等于可证明的 commit 日期。
- 现存已跟踪项目文档：187 份 Markdown 的路径/主题发现清单见 [source-catalog.json](source-catalog.json)。发现清单不是逐段技术审计 PASS。
- 本 skill 的专题：针对当前代码、政策和关键回归做了抽样到具体实现/测试的核验。未记录的开发动机不补造，私有原始历史不导出。
- 本机尚未提交的其他任务计划不纳入固定 catalog；入口仍会从 CURRENT/QUEUE 找到它们。后续合并后按维护约定更新。

## 阶段与重要变化

| 阶段 | 演进主题 | 证据入口及边界 |
|---|---|---|
| 2026-06，公开前资料 | RDP/RustDesk 双协议架构，SSH/VNC 扩展，后台连续性、音视频、终端 | [TECH_SPEC.md](../../../../docs/TECH_SPEC.md)、[RDP_RUSTDESK_BACKGROUND_CONTINUITY_TESTS.md](../../../../docs/RDP_RUSTDESK_BACKGROUND_CONTINUITY_TESTS.md)、[SSH_MODULE_UPGRADE_PLAN.md](../../../../docs/SSH_MODULE_UPGRADE_PLAN.md)；设计/历史材料，不能用其旧分支、地址和构建步骤操作当前仓库 |
| 2026-07-13 开源基线 | AGPL 发布、私有历史保护、合规流水线 | `a97c2ebdd`、`c6d3fbfde`、`ea36ff74b`；[FUNCTIONAL_CONTRACT.md](../../../../docs/compliance/baselines/1.0.5-agpl/FUNCTIONAL_CONTRACT.md) |
| 2026-07-14 RDP 稳定性 | shutdown、async teardown、presentation ownership、damage、scheduler、GL upload、动态分辨率 | 主线 PR #8–15，见完整节点表；具体代码在 `entry/src/main/cpp/rdp` |
| 2026-07-15–20 交互与控制面 | sheet 切换串行化、SSH 重连、IME、RDP 文件剪贴板、RustDesk Pro 地址簿 | `35318e9b6`、`ce00b11e8`、`ae1e52464`、`1f16f361a` |
| 2026-07-23–24 跨设备和会话 | 1.0.8 runtime、macOS toolchain/HDC、脱敏共享状态 | `a3f1ad3d8`、`dc715d230`、`bfae6ef30`；[1.0.8-release-notes.md](../../../../docs/test-results/1.0.8-release-notes.md) |
| 2026-08-01 数据生命周期 | 1.1.0 云同步集成 | `34946adbc`；相关 cloud plan 中方案存在迭代，当前策略见数据专题 |
| 2026-08-09 SSH 与主机体验 | SSH 工作台、主机本地个性化、权限披露 | `2feb12e0d`、`d840e662a`、`aeb0cdac5` |
| 2026-08-26–28 五协议演进 | Moonlight 接通及兼容、VNC 滚轮/光标、RustDesk 方向诊断、秘密可见性 | `c726b8642`、`928372c6c`、`0b8e5bf60`、`f3b41e5a6`、`181e79783` |
| 2026-08-29–09-05 集中升级 | IPv6、每协议缩放/滚轮、显示与指针、十二项反馈、1.1.5.1 | `b84224869`、`8edc18786`；[2026-09-06-pre-pro-current.md](../../../../docs/codex/archive/2026-09/2026-09-06-pre-pro-current.md)；代码/主机检查与设备/拓扑验收分开 |
| 2026-09-06 Pro 底座 | 沙盒商品/购买/订单查询、关闭取消、UI 样式 | 活动分支 `3df0439dc` → `ac83ccec7` → `6690cdbf4` → `0000d4ca4`；不是 main 发布事实 |

## 关键案例可直接追溯

| 案例 | 实现 commit | 当前专题 |
|---|---|---|
| RDP bind 后权威 geometry 重放 | `58ac524ab` | [渲染输入](lifecycle-rendering-input.md) |
| RDP 临时凭据 | `69c1c7f1c` | [RDP](protocols/rdp.md) |
| RDP 错误来源和严格 envelope | `9a911bfac`、`0a7559aa7` | [RDP](protocols/rdp.md) |
| RustDesk 显式 H.265 预认证交接 | `15632691b` | [RustDesk](protocols/rustdesk.md) |
| Dock 输入 fencing | `699d10184` | [渲染输入](lifecycle-rendering-input.md) |
| SSH 常用命令 | `d83a85811` | [SSH](protocols/ssh-sftp.md) |
| RustDesk 远端到本地剪贴板 | `9d3e5f853` | [渲染输入](lifecycle-rendering-input.md) |
| PC 首次快捷键默认/读取失败 | `fd9289d5c` | [渲染输入](lifecycle-rendering-input.md) |
| Pro 弹层关闭后继续 checkout | `ac83ccec7` | [购买](purchase-entitlements.md) |

## 从历史找到当前事实

```sh
git log --first-parent --date=short --format='%h %ad %s' main
git log --follow -- entry/src/main/ets/services/RdpPipelineGeometryReplayPolicy.ets
git show 58ac524ab -- entry/src/main/ets/services/RdpPipelineGeometryReplayPolicy.ets
rg -n '关键词或符号' docs/codex/plans docs/superpowers/plans entry/src/main
```

查询明确公开 main 或已授权活动分支，避免 `--all` 将私有 refs 混入导出。只有具体调查需要时按 AGENTS 的 history_tool 流程只读查看本地 archive；不把 archive 原文打包或推送。

## 已发现的过期/冲突材料

- `TECH_SPEC.md` 的双协议叙述不代表五协议现状。
- `BUILD_BASELINE.md` 和 README 部分 daemon 命令、机器路径、历史 dirty 状态不替代当前 AGENTS/status。
- `DECISIONS.md` 的重复 D-008/D-009/D-010 用完整标题消歧；云物理库 D-022 与当前 canonical 兼容策略冲突，详见 [数据专题](storage-cloud-security.md)。
- Moonlight 台账早期 DORMANT/LOCAL ONLY 与后期 runtime 接通并存，读取目标变更的最新证据。
- 用户于 2026-09-07 将开发基准推进到 API 26；旧 API23 ceiling 已在 AGENTS/DECISIONS 更新。这个基准决定不自动完成 API26/Pro 路线图中的具体功能或 acceptance pending。

版本文案还可查 [ReleaseNotesRegistry.ets](../../../../entry/src/main/ets/services/ReleaseNotesRegistry.ets)、[1.0.6-release-notes.md](../../../../docs/test-results/1.0.6-release-notes.md)、[1.0.7-release-notes.md](../../../../docs/test-results/1.0.7-release-notes.md)。面向用户的发布说明不是完整实现/验收证明。
