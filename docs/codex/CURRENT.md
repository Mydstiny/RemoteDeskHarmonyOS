# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-03 已 checkpoint；
  当前唯一代码任务是 N2-04 generation-fenced OH_AVCodec integration。
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Non-negotiable State

- 不影响 RDP、RustDesk、SSH/SFTP、VNC、云同步、备份和账户隔离；公共 decoder 改动先补
  旧协议失败回归，不新增 Moonlight 私有 decoder/session owner。
- `CloudSyncPolicy.CLOUD_SYNC_TABLES` 仍精确为原 8 表；`moonlightrecordv1` 仅为未来云表，
  三环境 AGC schema/auth/index receipt 前不得注册。
- FAB 只有一个 Moonlight 项，`enabled=false`，只有一个“即将支持”；不得提前创建可保存
  的假页面或可点击入口。
- 11 个 feature inputs 默认全 false；六项 release snapshot 未放行。平台能力默认
  11 pending、controller rumble 1 unsupported、0 supported。
- 两个允许的 `gpt-5.6-sol low` reviewer 名额均已使用，不得因压缩或新 checkpoint 重派；
  N2-03 无第三份审查回执，状态机应诚实显示 `REVIEW_REQUIRED`。

## Checkpoint Facts

- D1-D3：19/20 列 cloud/local envelope、16 列 app cache、四层设置、冲突/隔离、账户 barrier、
  Backup V3 与 deletion exact preview/terminal 已完成；ARM64 API 24 emulator owner-store
  `user_version=5`，19/20/16 列、tables=3、重启后 receipt=1。
- N1-01～N1-02：117 个锁定 upstream 文件、三个可重建 Git tree、唯一 CMake 边界和双 ABI
  private link 已完成，upstream bytes 与产品 NAPI/HAP 面保持隔离。
- N1-03～N1-08：唯一 owner lane、injected Host API、secure identity seam、pairing、Host Control、
  exact native bridge 和五个 typed NAPI 属性已完成 dormant contract；product identity/transport
  runtime proof 缺失，因此首包前 `runtime_proof_required`，不声明配对/目录/launch 可用。
- N2-01 `db5865c53`：只生成 deterministic stream offer。
- N2-02 `248e704ab`：唯一 hidden common-c adapter；官方 struct/mask、process-global callback、
  11-stage/deadline/termination、setup-derived video/audio、callback drain 和 RI/IV/RTSP cleanse。
- N2-03 `34d2ffa7a`：hidden `MoonlightVideoBridge`；adapter 在唯一 `.cpp` 内把官方
  `DECODE_UNIT/LENTRY` bounded 投影到 project view，bridge 复制 owned AU/fragment offset，
  保存 SPS/PPS/VPS generation，并冻结 IDR/backpressure/stale/teardown。上游 `LENTRY` 无
  offset，`DECODE_UNIT` 无 decodeNumber；只使用 `frameNumber`。product sink unavailable，
  无 OH_AVCodec/Surface/NAPI/ArkTS/UI/cloud/audio/input，`firstFrameReady=false`。

## N2-03 Verification

- host normal、strict `-Werror`、完整 TSan：**506/506 PASS**；ASan/UBSan clean rebuild
  连续三轮 **506/506 PASS**；scan-build 全目标零报告。
- 两 ABI `rdpnapi` 与官方 adapter probe PASS；每 ABI 91 条永久 command：`rdpnapi=48`、
  adapter=1、video bridge=1、probe=0。bridge 无平台媒体/NAPI include；`Limelight.h` 只在
  adapter `.cpp`。
- ABI 与 N2-02 基线逐项一致：arm64 defined/undefined 16103/705、x86_64 15634/703，
  两 ABI NAPI 子集各 147。
- `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 BUILD SUCCESSFUL；HAP SHA-256
  `d5311acdf2d8e02385cf7bf2d33bd737e971584058b0c90d9ef7c1a0bfa9d045`，423 paths 不变。
- API 23 双 ABI platform probe、三 tree/117 files、TOTP 251、Light、vendor、diff 和
  云表/FAB/truth 隔离检查均 PASS。

## Next

1. 只执行主计划 15.7.11 的 N2-04：新增窄 Moonlight decoder sink，使 N2-03 owned AU
   复用现有 `hw_decoder` registry、shared session owner、callback gate、Surface/renderer
   和 deferred retire；bridge 继续不 include 平台/NAPI 头。
2. 先冻结旧协议 create/bind/decode/rebind/detach/destroy、display、keyframe recovery 与锁序，
   再增加最窄 exact-owner pure-native seam；不得调用全局 setter 抢占其他协议 owner。
3. MVP 仅 runtime-proven H.264 8-bit 4:2:0。submit/PushInput/output callback 都不是首帧；
   exact generation 的 output→NativeImage update→renderer owner ack 三段齐全才可发布 receipt。
4. Product wiring、FAB、UI、云表及六项 truth 继续关闭；N2-05 才处理 Surface absent、PIP、
   后台与 rebind policy。

## Blockers

- `ohosTest@OhosTestCompileArkTS` 未注册（`00306054`）；151 个 Moonlight ArkTS tests 仅
  compile-registered，不声明设备 Hypium PASS。
- AGC development/test/production 的 `moonlightrecordv1` schema/auth/index receipt 缺失。
- 当前 HDC target 没有新的可复现 receipt；早期 RDB emulator receipt 仍有效。
- HAP/AppSpawn secure identity、H.264/NativeImage/renderer media 和 input capability probes 缺失。
- 两台真实 Sunshine host、网络/功耗/后台矩阵与用户 ARM64 实机最终验收仍 pending。
