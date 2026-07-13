# RDP/RustDesk Background Continuity — 端到端验证 (T-255)

> 建立时间: 2026-06-25 by Claude
> 计划来源: `docs/superpowers/plans/2026-06-25-rdp-rustdesk-background-session-continuity.md`

## 前置条件

- [ ] 一台可连接的 RDP 主机 (Windows, NLA 认证)
- [ ] 一台可连接的 RustDesk 主机 (如果需要)
- [ ] 一台带音频输出的远程主机 (用于音频连续性测试)
- [ ] hdc 连接 (`hdc -t 192.168.31.222:38451 shell`)
- [ ] hilog 已开启 (建议过滤关键字)

## 构建

```powershell
cd "C:\Users\14288\DevEcoStudioProjects\RemoteDesktop"
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' ...
```

确认: BUILD SUCCESSFUL, HAP 已安装到设备。

## 测试矩阵

### 1. RDP 后台连续性

| # | 操作 | 预期结果 | hilog 关键模式 | Pass/Fail |
|---|------|----------|---------------|-----------|
| 1.1 | RDP 连接成功 → Home 手势回桌面 | 连接保持, 无 disconnect 日志 | `detachForBackground: preserving protocol` | |
| 1.2 | 从桌面返回 RemoteDesktop | 画面恢复, 输入可用 | `doBackgroundRestoreRender: complete` | |
| 1.3 | RDP 已连接 → 点击断开按钮 | 完全断连 | `disconnectAndCleanup: reason=pc-disconnect-button` | |
| 1.4 | RDP 已连接 → 按返回键 | 完全断连 | `disconnectAndCleanup: reason=explicit-exit` | |
| 1.5 | RDP 已连接 → 最近任务清理 | 完全断连 | `Ability onDestroy` + native disconnect | |
| 1.6 | RDP 含音频 → Home 手势 | 音频继续, 无 destroyAudioPlayer | `AudioPhase.backgroundPlaying` | |

### 2. RustDesk 后台连续性

| # | 操作 | 预期结果 | hilog 关键模式 | Pass/Fail |
|---|------|----------|---------------|-----------|
| 2.1 | RustDesk 连接成功 → Home 手势 | 连接保持 | `detachForBackground: preserving protocol` | |
| 2.2 | 返回 RemoteDesktop | 画面恢复 | `doBackgroundRestoreRender: complete` | |
| 2.3 | RustDesk 已连接 → 显式退出 | 完全断连 | `disconnectAndCleanup` | |
| 2.4 | RustDesk 已连接 → 最近任务清理 | 完全断连 | native disconnect | |

### 3. 后台任务

| # | 操作 | 预期结果 | hilog 关键模式 | Pass/Fail |
|---|------|----------|---------------|-----------|
| 3.1 | RDP 连接 → Home 手势 | 后台任务启动 + 通知显示 | `[SESSION-BG] multiDeviceConnection task started` | |
| 3.2 | 点击通知 → 返回 RemoteDesktop | 画面恢复 | `doBackgroundRestoreRender` | |
| 3.3 | 无音频会话 → Home 手势 | 无 audioPlayback 任务 | 不存在 `[SESSION-BG-AUDIO]` | |
| 3.4 | 有音频会话 → Home 手势 | audioPlayback 叠加 | `[SESSION-BG-AUDIO] audioPlayback task started` | |
| 3.5 | 文件传输进行中 → Home 手势 | dataTransfer 和 multiDeviceConnection 独立共存 | 两个 notification ID 不同 | |

### 4. 边界情况

| # | 操作 | 预期结果 | hilog 关键模式 | Pass/Fail |
|---|------|----------|---------------|-----------|
| 4.1 | RDP idle (未连接) → Home 手势 | 正常 (无会话可保活) | 无 disconnect 或 preserve 日志 | |
| 4.2 | RDP 正在连接中 → Home 手势 | 连接尝试被取消 | 正常清理 | |
| 4.3 | Home 手势 → 返回 → 再 Home 手势 ×2 | 每次保活/恢复正常 | 无状态泄漏 | |
| 4.4 | 后台任务被系统拒绝 | 连接保持直到系统允许超时 | `[SESSION-BG-START] multiDeviceConnection rejected` | |

## hilog 命令

```powershell
# 采集连接和后台相关日志
hdc -t 192.168.31.222:38451 shell "hilog -T RD_DOMAIN,EXT_LOADER,RDP_ADAPTER,RUSTDESK_BRIDGE,GL_RENDERER,RemoteSessionBgTask" | Tee-Object bg-test.log

# 过滤关键事件
Select-String -Path bg-test.log -Pattern "detachForBackground|disconnectAndCleanup|doBackgroundRestoreRender|SESSION-BG|backgroundPreserved|disconnectAll"
```

## 期望的日志序列

### 正常后台保活:
```
[EntryAbility] Ability onBackground (background flag set, sessions preserved if active)
[RemoteDesktop] aboutToDisappear: background preserve (home gesture)
[RemoteDesktop] detachForBackground: preserving protocol + audio
[GL] detachForBackground: mark surface destroyed
[ExtLoader] detachRenderForBackground: OK
[SESSION-BG] multiDeviceConnection task started id=...
```

### 前台恢复:
```
[EntryAbility] Ability onForeground
[RemoteDesktop] aboutToAppear: restoring from background preserve sessionId=...
[RemoteDesktop] tryStartConnect: background restore — reattaching renderer only
[ExtLoader] reattachRenderForForeground: handle=...
[ExtLoader] requestFrameRefresh: sent to active adapter
[RemoteDesktop] doBackgroundRestoreRender: complete, session resumed
```

### 显式退出:
```
[RemoteDesktop] aboutToDisappear: full disconnect reason=explicit-exit
[RemoteDesktop] disconnectAndCleanup: reason=explicit-exit
[ExtLoader] disconnect: ...
[GL] disconnectAndCleanup: mark surface destroyed
[SESSION-BG] task stopped
```

## 签署

| 日期 | 测试人 | 结果 | 备注 |
|------|--------|------|------|
| | | | |
| | | | |
