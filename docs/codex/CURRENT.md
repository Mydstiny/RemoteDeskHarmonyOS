# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-05 已 checkpoint；
  当前唯一代码任务是 N2-06 dormant Opus→PCM bridge。
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
  N2-03/N2-04 无第三份审查回执，状态机应诚实显示 `REVIEW_REQUIRED`。

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
- N2-04 `bee0ac1da`：hidden pure decoder sink + OHOS port，复用既有 decoder/renderer
  exact owner、callback gate、NativeImage 和 retire lane；H.264 config-IDR recreate、typed
  admission 以及 output→NativeImage→actual EGL swap 三段首帧已冻结。archive 无
  factory caller/NAPI/ArkTS/UI/cloud/audio/input，HAP runtime proof 缺失，产品仍不可达。
- N2-05 `7992279c7`：hidden pure-native Surface lifecycle 组合 N2-04 sink/bridge；无 Surface
  在 copy/queue 前返回 `NoSurface`，temporary suspend exact detach 但保留 decoder handle，
  rebind 只接受同 key/decoder/display 与更高 Surface/renderer/runtime-proof generation；
  same-generation resize 不清首帧。无 ArkTS/PIP/NAPI/cloud/audio/input/product caller。

## N2-05 Verification

- host normal、strict `-Werror`、完整 TSan：**523/523 PASS**；ASan/UBSan clean rebuild
  连续三轮 **523/523 PASS**；scan-build 全目标零报告。
- 两 ABI `rdpnapi`、sink archive 和 callback-entry carrier PASS；每 ABI 94 条永久 command：
  `rdpnapi=48`、adapter=1、video bridge=1、decoder sink/lifecycle=3（总数 94）。
- ABI 与 N2-04 基线逐项一致：arm64 defined/undefined 16103/705、x86_64 15634/703，
  两 ABI NAPI 子集各 147。
- `default@OhosTestCompileArkTS` 与 signed `assembleHap` 均 BUILD SUCCESSFUL；HAP SHA-256
  `e2598c67896e04949409dbe93d26ec8a7ee390a53e1052aa0c7c8e0c692453c8`，423 paths 不变。
- API 23 双 ABI platform probe、三 tree/117 files、TOTP 251、vendor 与前置 Light receipt
  通过；最终文档 Light/diff/state 在本 checkpoint 文档提交前重跑。

## Next

1. 只执行主计划 15.7.13 的 N2-06：新增 hidden pure-native `MoonlightAudioBridge` 和
   deterministic test；消费 N2-02 已验证的 `MoonlightCommonCAudioSelection` 与 borrowed
   payload，但不接 common-c product media port、OHAudio、NAPI、ArkTS、UI、云或输入。
2. 唯一 codec 为仓库已有 libopus 1.5.2；不得复制 RustDesk `AudioWorker`、静态链接第二份
   Opus 或新建 audio/session owner。MVP 仅接受 exact 48 kHz stereo family-1
   multistream config；5.1/7.1 与任何降混均 typed `Unsupported`，不是静默 stereo。
3. payload/PLC 必须同步复制到 bridge 自有有界 work item，解码为 interleaved S16LE；严格
   核对 key/profile/generation、packet/frame/PCM 上限、start/stop/cleanup 顺序、blocked decode
   drain 和 zeroization。音频 ready/PCM accepted 永不改变视频 first-frame 或发布 truth。
4. N2-07 才按 exact owner 接现有 `AudioPlayerNapi::DispatchActiveNative` 和其 registry/queue；
   S1-08 才做 ArkTS/PIP/后台装配。runtime receipt 前 FAB、云表和六项 truth 继续关闭。

## Blockers

- `ohosTest@OhosTestCompileArkTS` 未注册（`00306054`）；151 个 Moonlight ArkTS tests 仅
  compile-registered，不声明设备 Hypium PASS。
- AGC development/test/production 的 `moonlightrecordv1` schema/auth/index receipt 缺失。
- 当前 HDC target 没有新的可复现 receipt；早期 RDB emulator receipt 仍有效。
- HAP/AppSpawn secure identity、H.264/NativeImage/renderer media 和 input capability probes 缺失。
- 两台真实 Sunshine host、网络/功耗/后台矩阵与用户 ARM64 实机最终验收仍 pending。
