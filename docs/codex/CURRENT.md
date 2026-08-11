# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Head checkpoint: `c38ff6265` + review fixes `71e9902c9`, `7eaad950b`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-08、N3-01～N3-08、
  U1-01～U1-03 已 checkpoint；N2-09 external pending；下一任务 U1-04。
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Product Decisions

- Moonlight 当前只开发本地主机存储。在线云表仍精确为原 8 表；不得注册、上传或创建可用的
  `moonlightrecordv1`，不得接 Moonlight cloud selection/transfer/secret recovery。
- Moonlight UI 的唯一设计与交互基线是现有 RustDesk FAB、`HostProtocolPicker`、
  `RustDeskAddFlow` 和单 Sheet 生命周期；不以 VNC 页面作为设计或 scaffold 来源。
- Moonlight 入口保持默认禁用：末项、0.58 opacity、唯一“即将支持”、点击零路由。
- 官方图标只标识协议，不代表 Moonlight 官方背书或串流能力已开放。
- 实体手柄必须由 S1-05A 的 HarmonyOS native listener 产生完整状态，经 N3-08→N3-05→N3-01→
  official common-c 发送；ArkTS 不编码或直发手柄协议。

## U1-01～U1-03 Checkpoint

- `c38ff6265`：Moonlight 与 RustDesk 继续调用同一个 `protocolOption()`，新增纯
  `HostProtocolPickerPolicy`；未来 enabled route 合同一致，默认 disabled route 为空。
- `71e9902c9`：disabled callback 计数、enabled route、brand→system fallback 和 enabled/disabled
  tint 均进入纯 policy 测试；REUSE/SBOM/NOTICE/source offer 与 Light 精确门禁闭环。
- `7eaad950b`：补齐 `GPL-3.0-only` 正文、SPDX package verification code，并把组件 fallback
  收束到唯一 `moonlightSystemFallbackIcon()` 映射。
- 官方 Moonlight Qt `2e13ed9977bc31c73caf8428f08f58d793313ece` 图标已做确定性单色可着色转换：
  upstream SHA-256 `6fd0ee4f...`，packaged SHA-256 `4f5ef547...`，加载失败回退
  `sys.symbol.gamecontroller_fill`；provenance/NOTICE/SPDX/source offer/hash 门禁已同步。
- 未修改 `RustDeskAddFlow.ets`、`HostListPage.ets`、CloudStore、CloudSyncPolicy、任何 native 或
  其他协议业务文件；禁用卡片不读写 repository、不访问 native/network、不启动后台任务。
- 现有 native N1/N2/N3 继续 dormant；真实 GameController listener/typed NAPI 仍只在 S1-05A。

## Verification

- `default@OhosTestCompileArkTS`: BUILD SUCCESSFUL；154 个 Moonlight focused tests / 21 describe
  compile-registered，未声明设备 Hypium 执行。
- `assembleHap`: BUILD SUCCESSFUL；signed HAP 已生成、通过沙箱外 HDC 安装并启动。
- HDC UI：协议选择页显示禁用色官方 Moonlight 图标；点击后仍停留“添加远程主机”，且只有一个
  “即将支持”，无添加路由。
- Open-source Light、117-file Moonlight vendor、SBOM JSON、官方/本地资源 hash、
  `git diff --check` 与精确隔离检查均 PASS。
- Reviewer: 复用 task `019fe966-d99a-7ce1-8b53-4ef725597053` 完成最终复核；
  `99eecdbea..7eaad950b` P0/P1/P2/P3 全 0，receipt
  `moonlight-u1-01-03-gpt5-7eaad950b-2026-08-11`，未新建 reviewer。

## Next

1. U1-04：新建 Moonlight 四步本地添加流；视觉/交互直接沿用 RustDesk header、模式卡、字段、
   错误提示、44vp 主按钮、返回/关闭与单 Sheet owner，不复制 RustDesk relay/TOTP/credential 状态。
2. S1-05A：接真实 HarmonyOS GameController native listener 与窄 typed NAPI；真机 receipt 前 capability false。
3. N2-09：真实 Sunshine + ARM64 设备完成分辨率、帧率、时长、温控、网络和生命周期矩阵。

## Blockers

- `ohosTest@OhosTestCompileArkTS` 未注册（`00306054`），不能声明 on-device Hypium PASS。
- HAP/AppSpawn secure identity、真实 Sunshine transport/media、首帧和实体手柄 runtime 仍未证明。
- N2-09 需要真实 Sunshine 与用户 ARM64 实机；不阻止 U1-04 的 fail-closed 本地 UI 开发。
