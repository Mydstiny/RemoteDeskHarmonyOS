# Shared Current State

## Active Task

- Task: `moonlight-complete-upgrade`
- Base: `main@aeb0cdac5`; branch: `codex/moonlight-complete-upgrade`
- Phase: G0、D1-D3 local/dormant、N1-01～N1-08、N2-01～N2-08、N3-01～N3-08 已 checkpoint；N3-08
  代码为 `fef723770`，审查修复为 `6787cc3fb`。N2-09 等待真实设备，下一任务为 U1-01；Moonlight 暂不接入云同步，云方案 parked。
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
- 最多两个 `gpt-5.6-sol low` reviewer 实例；后续复核必须复用既有 task ID，不得新建第三个；
  N3-08 已由既有 task `019fe966-d99a-7ce1-8b53-4ef725597053` 复核 PASS，未新建 reviewer。

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
- N3-05 `1aadfba24`：hidden `MoonlightControllerMapper` 直接投影 official common-c arrival/state 参数，冻结 API 23 button/axis/trigger/hat、7%/13% deadzone、Y 反向、stable slot 0、full-state frame、background/disconnect neutral、exact generation 与 retry；GameControllerKit 只做双 ABI compile-link probe，无真实双手柄证据时硬限制一槽，无产品 caller。
- N3-06 `baa9cafef`：hidden `MoonlightControllerFeedback` 以 official API 与 exact physical-device evidence
  交集控制 rumble/trigger rumble/RGB LED/motion/battery，adaptive trigger 独立门禁；API 23
  product evidence 全 false，unsupported 零 port 调用。固定单 pending retry、200Hz motion、120s battery refresh、exact owner/device/operation generation 和 release 生命周期；无产品 caller。
- N3-07 `02cb13aae` + `36b4e13df` + `337c4f35e` + `ee073afcb`：hidden policy 在 mapper release 前原子关闭
  bridge admission，只放行 bounded lifecycle release；覆盖全部 lifecycle trigger、component permanent
  failure/owner loss/pending→stop、suspended→stop、stale stop、exact retry/idempotence 和 local-terminal。
- N3-08 `fef723770` + `6787cc3fb`：hidden fixed-capacity controller aggregator/layout validator；物理完整状态和虚拟语义
  只经 N3-05→N3-01→common-c，共享 slot 0 但有 source/device/generation fence。双向换源固定
  disconnect→boundary retry→resume→higher generation；retired lane 拒绝旧事件且可复用。真实 listener/NAPI 留到 S1-05A。

## N3-08 Verification

- normal/strict：**714 total / 698 passed / 16 failed**；16 项仅为既有 VNC TLS fixture，28 个 N3-08
  tests 全 PASS。ASan/UBSan 三轮、TSan、analyzer、双 ABI、两项 Hvigor、signed HAP、Light/diff 全 PASS。
- archive 无 caller 且未进入 `rdpnapi`；动态符号数仍为 arm64 **16114/705**、x86_64 **15645/703**。
  未改旧协议/Common InputHandler/共享媒体/ArkTS/UI/云；无真机 receipt，不声明产品手柄或串流可用。
- reviewer P0/P1/P2/P3 全 0；receipt `moonlight-n3-08-gpt5-6787cc3fb-2026-08-11`。

## Next

1. U1-01：先冻结 VNC sm/md/lg/xl、短屏和大字体布局/交互基线，再提取无协议状态、无图标硬编码的
   `RemoteConfigSheetScaffold.ets`，并把 `VncSheetScaffold` 变成薄 wrapper；VNC DOM、截图、交互必须零差异。
2. N2-09 保持 external pending：真实设备 720p/1080p、30/60fps、2 小时、温控、前后台/PIP/
   旋转和 H.264+Opus receipt 只能由真实 Sunshine 与用户 ARM64 实机提供。
3. S1-05A 才把 HarmonyOS GameController native listener 与虚拟控制器窄 typed NAPI 接入 N3-08；
   ArkTS 不编码或直发协议，实体 listener 仍只提供原生完整状态。
4. U1/S1 UI、设置、目录、连接浮层和生命周期只接现有本地 Repository/cache、Host Control
   和媒体前置条件，不增加 Moonlight 云状态或同步设置；runtime receipt 前 FAB 与六项 truth 继续关闭。

## Blockers

- `ohosTest@OhosTestCompileArkTS` 未注册（`00306054`）；151 个 Moonlight ArkTS tests 仅
  compile-registered，不声明设备 Hypium PASS。
- 当前 HDC target 没有新的可复现 receipt；早期 RDB emulator receipt 仍有效。
- HAP/AppSpawn secure identity、H.264/NativeImage/renderer media 和 input capability probes 缺失。
- N2-09 两台真实 Sunshine、用户 ARM64 实机的媒体/网络/功耗/生命周期矩阵仍 pending，不阻止 dormant N3 合同开发。
