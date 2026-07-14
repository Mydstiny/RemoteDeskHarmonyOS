# R0-R6 真机验证清单

> 生成时间: 2026-06-16 | 构建: BUILD SUCCESSFUL (432 ms) | HAP: entry-default-signed.hap (12.8 MB)

## 前置条件

```bash
# 1. 安装 HAP 到设备
hdc install entry/build/default/outputs/default/entry-default-signed.hap

# 2. 查看日志 (另开终端)
hdc hilog | grep -E "RDP_NAPI|GL_RENDERER|HW_DECODER|RDP_ADAPTER|RUSTDESK|AUDIO|CLIPBOARD|ExtLoader"
```

## R0: 基础通路

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 0.1 | 应用启动不闪退 | GuidePage → LoginPage → HostListPage 正常 | ⬜ |
| 0.2 | `listProtocols()` 返回 4 协议 | hilog: "listProtocols: 4 个协议" | ⬜ |
| 0.3 | 添加 RDP 主机, 点击连接 | 进入 RemoteDesktop 页面, 显示连接中 | ⬜ |
| 0.4 | 连接失败展示错误码 | UI 显示 "连接被拒绝 [E-CONNECT-2]" | ⬜ |
| 0.5 | 返回 HostListPage | 不闪退, renderer/decoder/session 释放 | ⬜ |

## R1: XComponent 上屏

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 1.1 | RemoteDesktop 连接后不黑屏 | 显示蓝色 (#0033CC) 清屏, hilog: "testRender: 蓝色清屏已上屏" | ⬜ |
| 1.2 | hilog 确认 surface 模式 | "[GL] ✓ XComponent window surface" (非 Pbuffer) | ⬜ |
| 1.3 | 旋转/分屏后 viewport 正确 | SurfaceChanged 回调触发, 蓝色清屏不变形 | ⬜ |
| 1.4 | 断开→返回→再次连接 | 不泄漏: 第二次连接仍显示蓝色 | ⬜ |

## R2: 硬解

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 2.1 | RemoteDesktop 启动时 initDecoder | hilog: "[Decoder] ✓ 解码器启动成功 (Surface模式)" | ⬜ |
| 2.2 | testDecoderH264 | hilog: "已送入 52 bytes", 不崩溃 | ⬜ |
| 2.3 | 断开连接 | hilog: "[Decoder] Destroy" 无残留 callback | ⬜ |

## R3: FreeRDP

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 3.1 | 选择 RDP 协议连接 | hilog: "[RDP] FreeRdpAdapter created (skeleton)" | ⬜ |
| 3.2 | TCP 握手到 MCS | hilog: "RDP skeleton session" (或连接失败) | ⬜ |
| 3.3 | FreeRDP submodule 存在 | `git submodule status` 显示 freerdp/ commit | ⬜ |

### R3.1: RDP 长连接退出稳定性

采集 `RDP-SHUTDOWN` 与 `ExtLoader][SHUTDOWN` 日志。每次退出必须按同一 generation
出现 `request`、`input-stop`、`trailing-stop`、`frame-pump-stop`、
`connect-join`、`event-stop`、`drive-join`、`freerdp-disconnect`、`post-disconnect`、`context-free`、
`complete`，并以 ArkTS `native-disconnect-return` 和 `arkts-return` 结束。

| # | 场景 | 预期 | 实际 |
|---|------|------|------|
| 3.1.1 | 连接 2 分钟后正常退出 | 主界面立即可交互，无缺失 teardown 阶段 | ⬜ |
| 3.1.2 | 持续鼠标与键盘输入时退出 | input worker 完成后才进入 FreeRDP disconnect | ⬜ |
| 3.1.3 | 连接 30 分钟后退出 | 无 ANR/崩溃，所有 worker/context 释放 | ⬜ |
| 3.1.4 | Home/前台恢复 10 次后退出 | renderer detach/restore 后 teardown 完整 | ⬜ |
| 3.1.5 | 共享盘、音频、剪贴板分别开关 | connect/drive join 均有结束日志 | ⬜ |
| 3.1.6 | 连续连接/断开 20 次 | 无残留 session、线程、renderer 或 audio | ⬜ |
| 3.1.7 | 连接 2 小时后退出 | UI 不冻结，RSS/PSS 不持续线性增长 | ⬜ |

## R4: RustDesk 安全

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 4.1 | RustDesk 协议注册 | hilog: "[RustDesk] bridge registered (IPC mode, safe)" | ⬜ |
| 4.2 | 选择 RustDesk 连接 | hilog: "IPC connect to helper failed (helper not running?)" | ⬜ |
| 4.3 | 明文密码路径不可达 | grep 源码: `rdAuthPassword` 仅在 `#ifdef RUSTDESK_EXPERIMENTAL` 内 | ⬜ |

## R5: 音频/剪贴板

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 5.1 | initAudioPlayer | hilog: "[Audio] ✓ Renderer running: 48000Hz 2ch" | ⬜ |
| 5.2 | getClipboardText/setClipboardText 不崩溃 | ArkTS 调用返回空字符串/不报错 | ⬜ |
| 5.3 | 断开连接后 audio player 释放 | hilog: "[Audio] Destroyed" | ⬜ |

## R6: 性能/质量

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| 6.1 | 帧级 DEBUG 日志不输出 | hilog 中无 "frame %" 或 per-frame DEBUG | ⬜ |
| 6.2 | INFO 级别状态变更正常输出 | connect/disconnect/start 等有 INFO 日志 | ⬜ |
| 6.3 | 长时间运行无内存泄漏 | 连接→断开循环 10 次, hilog 无异常 | ⬜ |

## 主机安全锁

| # | 验证项 | 预期 | 实际 |
|---|--------|------|------|
| L.1 | 主机卡片显示锁图标 | 已锁主机显示 SymbolGlyph(lock) | ⬜ |
| L.2 | 点击已锁主机 → 生物识别弹窗 | 系统认证 Widget 弹出 | ⬜ |
| L.3 | 取消认证 → 不进入连接 | 返回 HostListPage | ⬜ |
| L.4 | 通过认证 → 进入 RemoteDesktop | 正常连接 | ⬜ |

---

**测试设备**: ____________ | **系统版本**: ____________ | **测试人**: ____________ | **日期**: ____________
## Open-source release gate

- [ ] About shows AGPL-3.0-or-later and opens the matching GitHub source.
- [ ] RDP, RustDesk, SSH/SFTP and VNC behavior matches the frozen baseline.
- [ ] CloudSync, host lock, theme, background restore and existing data remain unchanged.
- [ ] Source tag, HAP hash, SBOM hash, protocol hashes and manifest agree.
- [ ] AGConnect/API/signing credentials have been rotated and are not tracked.
