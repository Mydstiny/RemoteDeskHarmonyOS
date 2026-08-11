# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-08、N3-01～N3-04 已 checkpoint；
  N3-04 代码 checkpoint 为 `ebd2fa0bc5`。N2-09 等待真实设备，当前唯一可执行代码任务为
  dormant N3-05。2026-08-10 决策为
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
  N2-03～N3-04 无第三份审查回执，状态机应诚实显示 `REVIEW_REQUIRED`。

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
- N3-01 `fe46025ef`：hidden `MoonlightInputBridge` 统一承载 exact session/generation/
  owner/input generation、device/source/source generation/sequence/monotonic timestamp；复用唯一
  `MoonlightSessionOwner` 与共享跨协议 `SessionSinkOwnerLease`，固定最多 32 个 source lane 和
  64-byte payload，完成 stale/duplicate/backpressure、失焦/停止 neutral flush、retry、resume、
  cleanup 和并发序列化合同。未修改公共 `InputHandler`，无产品 caller、NAPI、ArkTS、UI 或云。
- N3-02 `a552b30a2`：hidden `MoonlightKeyboardMapper` 把现有 HarmonyOS key namespace 映射为
  官方 `0x8000|VK` 合同；固定 8 个普通键、双侧四类修饰键与最多 16 条释放命令，完成 once/lock、
  物理键/UTF-8 文本分流、逐命令状态提交、backpressure 精确续传、跨设备 key-up 拒绝、全量反序
  释放与物理 Esc 本地逃生。无产品 caller、公共 InputHandler、NAPI、ArkTS、UI、云、线程或队列。
- N3-03 `1787da821`：hidden `MoonlightPointerMapper` 定义 absolute/relative pointer、五键、
  横纵高分辨率滚轮和 physical-pixel content-rect 映射；覆盖 letterbox/fill/1:1/pan、四向旋转、
  DPI 不变、fraction residual、exact geometry/source generation、逐命令状态提交、精确续传及反序
  release-all。capture/constraint/raw-relative 只解析能力并保持 product unavailable；无 caller、
  公共 InputHandler、NAPI、ArkTS、UI、云、线程或队列。
- N3-04 `ebd2fa0bc5`：hidden `MoonlightTouchMapper` 复用 N3-03 pointer 事务，冻结官方 28-byte
  direct-touch、多点稳定 id、cancel/cancel-all、旋转/内容矩形、overlay 生命周期互斥，以及一指
  光标/轻点、双指滚动/右键、长按拖拽、三指本地工具条；固定 10/3 contacts 与 16 observed lanes，
  capability、generation、backpressure 和 mode-switch flush 均 fail closed，无产品 caller。

## N3-04 Verification

- host normal 连续三轮与 strict 最终：**627 total / 611 passed / 16 failed**；16 个失败仍仅为既有 VNC
  本地 TLS fixture `start()` 环境失败，新增 21 个 N3-04 focused tests 全 PASS。
- ASan/UBSan 连续三轮与最终 TSan 同为 611/16，均无 sanitizer report；focused clang analyzer
  零诊断。arm64-v8a/x86_64 均生成非空私有 archive；无 caller 时 archive object 不进入
  `rdpnapi`，两 ABI defined/undefined 动态符号数量仍为 arm64 **16114/705**、x86_64
  **15645/703**，本地/动态符号均无 `MoonlightTouch`/`MoonlightPointer`/`MoonlightInput`。
- 两项 Hvigor 与 signed `assembleHap` 均 BUILD SUCCESSFUL；signed HAP 共 333 paths。
- Light、vendor 与 `git diff --check` 通过；只改 Moonlight touch/pointer 私有层、focused test 和
  CMake 私有 target，未改生产旧协议、common-c、公共 InputHandler、共享 telemetry/audio/render、
  ArkTS/UI/云。HDC `Connect server failed`，不声明真机触控或 Sunshine runtime 能力。

## Next

1. N3-05：基于 API 23 probe 建立 dormant 实体控制器映射、轴/trigger/dead-zone、稳定 slot 与
   断开 neutral 合同；多玩家能力无实机证据时只允许一槽，不接 NAPI/ArkTS/UI/product caller。
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
