# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-08 已 checkpoint；
  N2-08 代码 checkpoint 为 `57b1d7da4`。N2-09 等待真实设备，当前唯一可执行代码任务为
  dormant N3-01。2026-08-10 决策为
  Moonlight 暂不接入云同步，当前只推进本地主机存储；云表/CloudSync 方案 parked。
- Authoritative plan: `docs/superpowers/plans/2026-07-28-moonlight-harmonyos-complete-upgrade-plan.md`
- Live ledger: `docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md`

## Non-negotiable State

- 不影响 RDP、RustDesk、SSH/SFTP、VNC、云同步、备份和账户隔离；公共 decoder 改动先补
  旧协议失败回归，不新增 Moonlight 私有 decoder/session owner。
- `CloudSyncPolicy.CLOUD_SYNC_TABLES` 仍精确为原 8 表；Moonlight 当前只使用
  `moonlightlocalrecords` 与 `moonlightappcache`，不得创建/注册/上传 `moonlightrecordv1`，
  不实例化 Moonlight CloudSync/selection/transfer。
- FAB 只有一个 Moonlight 项，`enabled=false`，只有一个“即将支持”；不得提前创建可保存
  的假页面或可点击入口。
- 11 个 feature inputs 默认全 false；六项 release snapshot 未放行。平台能力默认
  11 pending、controller rumble 1 unsupported、0 supported。
- 两个允许的 `gpt-5.6-sol low` reviewer 名额均已使用，不得因压缩或新 checkpoint 重派；
  N2-03/N2-04 无第三份审查回执，状态机应诚实显示 `REVIEW_REQUIRED`。

## Checkpoint Facts

- D1-D3：19/20 列 cloud/local envelope、16 列 app cache、四层设置、冲突/隔离、账户 barrier、
  Backup V3 与 deletion exact preview/terminal 已完成；ARM64 API 24 emulator owner-store
  `user_version=5`，19/20/16 列、tables=3、重启后 receipt=1。Moonlight 当前只消费 local
  overlay/cache；云表与云生命周期停靠。
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
- N2-06 `8d2fd15b3`：hidden pure-native Opus multistream→interleaved S16LE bridge；只接受 exact
  48 kHz stereo family-1，复用唯一 pinned Opus 1.5.2，修正 common-c `nullptr+0` PLC callback，
  固定 1400-byte packet/23040-byte PCM 上限、single in-flight、owner/config/operation generation、
  stop drain/retry、cleanup 与 scratch zeroization。无 `audio_player`/OHAudio/NAPI/ArkTS/UI/
  cloud/input/product caller，音频结果不改变视频 first-frame 或 release truth。
- N2-07 `9272f1c9c`：hidden exact-owner PCM sink 把 N2-06 输出委托到既有 `audio_player`
  registry/有界 queue；复用 `DecoderSessionIdentity`、mute、focus/background suspend+flush、
  resume prebuffer 与 exact stop/cleanup。无私有 OHAudio owner/queue/worker/NAPI/产品 caller。
- N2-08 `57b1d7da4`：hidden、固定 256 槽上限的 `MoonlightMediaClockStats` 聚合
  network assembly、decode queue/decode/render/end-to-end、host processing、audio queue 与
  common-c exact RTP/FEC counters；optional 保持 absent-vs-zero，owner/window/source generation、
  counter decrease、节流、饱和、stop/cleanup 和迟到 sample 均 fail closed。无日志、线程、
  NAPI/ArkTS/UI/cloud/product caller。

## N2-08 Verification

- host normal/strict：**561 total / 545 passed / 16 failed**；16 个失败仍仅为既有 VNC 本地 TLS
  fixture `start()` 环境失败，新增 13 个 N2-08 focused tests 全 PASS。
- ASan/UBSan 连续三轮与 TSan 同为 545/16，均无 sanitizer report；focused clang analyzer
  零诊断。arm64-v8a/x86_64 均生成私有 archive；无 caller 时 archive object 不进入
  `rdpnapi`，两 ABI defined/undefined 动态符号集合与 N2-07 产物逐项一致。
- 两项 Hvigor 与 signed `assembleHap` 均 BUILD SUCCESSFUL；当前 signed HAP SHA-256
  `5bf7cd91809c7c9e46cf15aa1d8b963946f0d805b91a867ef98492aa441860fe`，333 paths。
- Light 与 `git diff --check` 通过；仅改 Moonlight 新文件、focused test 和私有 CMake target，
  未改 common-c、共享 telemetry/audio/render 或任一旧协议业务源。HDC 无 target，不声明真实
  Sunshine、媒体延迟或性能能力。

## Next

1. N3-01：新建 dormant `MoonlightInputBridge`，所有输入携带 exact session/generation/device/
   source/timestamp，复用唯一 Moonlight owner lane；不接 InputHandler、NAPI、ArkTS 或 UI。
2. N2-09 保持 external pending：真实设备 720p/1080p、30/60fps、2 小时、温控、前后台/PIP/
   旋转和 H.264+Opus receipt 只能由真实 Sunshine 与用户 ARM64 实机提供。
3. S1-08 才消费 N2-05 native contract，接现有 `NativeSessionHandles`/PIP/background 生命周期；
   runtime receipt 前 FAB、云表和六项 truth 继续关闭。
4. U1/S1 UI、设置、目录、连接浮层和生命周期只接现有本地 Repository/cache、Host Control
   和媒体前置条件，不增加 Moonlight 云状态或同步设置。

## Blockers

- `ohosTest@OhosTestCompileArkTS` 未注册（`00306054`）；151 个 Moonlight ArkTS tests 仅
  compile-registered，不声明设备 Hypium PASS。
- 当前 HDC target 没有新的可复现 receipt；早期 RDB emulator receipt 仍有效。
- HAP/AppSpawn secure identity、H.264/NativeImage/renderer media 和 input capability probes 缺失。
- N2-09 真实设备媒体、功耗、前后台/PIP/旋转矩阵仍 pending，不阻止纯 dormant N3 合同开发。
- 两台真实 Sunshine host、网络/功耗/后台矩阵与用户 ARM64 实机最终验收仍 pending。
