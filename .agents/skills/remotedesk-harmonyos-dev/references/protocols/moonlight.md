# Moonlight / Sunshine

核验快照：2026-09-07，`0000d4ca4`。这是独立的配对、host control、应用目录和媒体/输入链路，不以四协议 adapter 的单一路径解释。

## 分层入口

| 阶段 | 文件 |
|---|---|
| 主机和应用 | [MoonlightHostDetailPage.ets](../../../../../entry/src/main/ets/pages/MoonlightHostDetailPage.ets)、[MoonlightAppCatalogPage.ets](../../../../../entry/src/main/ets/pages/MoonlightAppCatalogPage.ets) |
| 会话恢复 | [MoonlightSessionCoordinator.ets](../../../../../entry/src/main/ets/services/MoonlightSessionCoordinator.ets)、[MoonlightSessionRecoveryRuntime.ets](../../../../../entry/src/main/ets/services/MoonlightSessionRecoveryRuntime.ets) |
| native runtime | [MoonlightProductRuntime.cpp](../../../../../entry/src/main/cpp/moonlight/runtime/MoonlightProductRuntime.cpp)、[MoonlightProductStreamingRuntime.cpp](../../../../../entry/src/main/cpp/moonlight/runtime/MoonlightProductStreamingRuntime.cpp) |
| 信任/配对 | [MoonlightSecureIdentity.cpp](../../../../../entry/src/main/cpp/moonlight/security/MoonlightSecureIdentity.cpp)、[MoonlightPairingManager.cpp](../../../../../entry/src/main/cpp/moonlight/pairing/MoonlightPairingManager.cpp) |
| 媒体 | [MoonlightVideoDecoderSink.cpp](../../../../../entry/src/main/cpp/moonlight/media/MoonlightVideoDecoderSink.cpp)、[MoonlightVideoSurfaceLifecycle.cpp](../../../../../entry/src/main/cpp/moonlight/media/MoonlightVideoSurfaceLifecycle.cpp)、[MoonlightAudioBridge.cpp](../../../../../entry/src/main/cpp/moonlight/media/MoonlightAudioBridge.cpp) |
| 输入 | [MoonlightProductInputRuntime.cpp](../../../../../entry/src/main/cpp/moonlight/input/MoonlightProductInputRuntime.cpp)、[MoonlightControllerAggregator.cpp](../../../../../entry/src/main/cpp/moonlight/input/MoonlightControllerAggregator.cpp) |
| 能力和数据 | [MoonlightCapabilityPolicy.ets](../../../../../entry/src/main/ets/services/MoonlightCapabilityPolicy.ets)、[MoonlightCloudDeletionPolicy.ets](../../../../../entry/src/main/ets/services/MoonlightCloudDeletionPolicy.ets)、[MoonlightBackupPolicy.ets](../../../../../entry/src/main/ets/services/MoonlightBackupPolicy.ets) |

## 必查边界

1. 配对凭据、主机身份、控制请求、launch accepted 与真正 streaming active 分开。终止或错误事件可能在状态提交期间发生，不能让 accepted 覆盖后来的 terminal。
2. HTTP control 请求 framing/UUID/cancel 与媒体连接分别诊断；目录缓存不证明主机实时在线或可开始串流。
3. 视频 source/surface/decoder 代次一致；音频、网络和 decoder 的释放有明确 owner。翻转检查读 [共享专题](../lifecycle-rendering-input.md)。
4. 手柄聚合检查物理设备变化、按键释放、feedback owner 和模拟/实体路由。成功提交输入不证明 stream 已消费。
5. Moonlight 可选第九云表不得破坏旧八表恢复；delete、tombstone、identity、backup/selection 兼容分别验证，见 [数据专题](../storage-cloud-security.md)。

## 上游和验证

[UPSTREAM.lock.json](../../../../../entry/src/main/cpp/moonlight/upstream/UPSTREAM.lock.json)、[MOONLIGHT_COMMON_C_PROVENANCE.md](../../../../../docs/compliance/MOONLIGHT_COMMON_C_PROVENANCE.md) 固定上游；[build_moonlight_common_vendor.sh](../../../../../scripts/build_moonlight_common_vendor.sh)、[verify_moonlight_vendor.py](../../../../../scripts/verify_moonlight_vendor.py) 是现有构建/核验入口。上游代码与图标来源不可混淆。

从 [moonlight_video_decoder_sink_test.cpp](../../../../../entry/src/main/cpp/test/moonlight_video_decoder_sink_test.cpp) 与 `entry/src/test/Moonlight*.test.ets` 选择相关验证。实际串流还需受控 Sunshine、配对状态、软硬解、音频、输入、前后台和网络证明。

[2026-08-09-moonlight-implementation-ledger.md](../../../../../docs/codex/plans/2026-08-09-moonlight-implementation-ledger.md) 是阶段台账，含 DORMANT、LOCAL ONLY、PARTIAL 和后续接通阶段。读目标条目及其后续更新，不能把早期 dormant 结论当成最终代码，也不能把 contract test PASS 当成产品可用。
