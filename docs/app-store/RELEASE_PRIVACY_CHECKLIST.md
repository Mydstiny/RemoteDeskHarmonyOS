# 发布与隐私自查清单

更新日期：2026-06-30

范围：本清单用于 AppGallery 提交前的最后人工审计。当前云同步策略冻结，不在本清单中推进 schemaVersion、tombstone、deviceId 或冲突合并策略变化；这里只检查发布配置、权限、敏感配置、日志和能力文案是否真实可发布。

## 一、发布配置

| 检查项 | 当前证据 | 发布前结论 |
|---|---|---|
| 最终包名 | `AppScope/app.json5` 仍为 `com.example.remotedesktop` | 必须替换为正式包名，并与 AppGallery Connect 应用一致 |
| 厂商名 | `AppScope/app.json5` 仍为 `example` | 必须替换为正式开发者/组织名称 |
| 签名材料 | `build-profile.json5` 当前存在本地调试签名改动 | 上架包必须使用 Release Profile |
| AGC 应用配置 | `entry/src/main/resources/rawfile/agconnect-services.json` 包含示例包名、`client_secret`、`api_key` | 发布前必须由正式 AGC 应用重新下载并替换；不要把个人调试应用配置当成发布配置 |
| client_id 元数据 | `entry/src/main/module.json5` 写死 `client_id` | 必须确认与正式 AGC 应用一致 |

## 二、权限与触发入口

| 权限 | 源码位置 | 当前用途 | 发布前动作 |
|---|---|---|---|
| `ohos.permission.INTERNET` | `entry/src/main/module.json5` | 远程连接、RustDesk 中继、华为账号/Cloud DB 同步 | 保留 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | `entry/src/main/module.json5` | 远程会话后台保活、后台音频/文件传输 | 保留，但商店权限说明必须写清楚远程连接场景 |
| `ohos.permission.CAMERA` | `entry/src/main/module.json5` | TOTP 二维码扫描时按需申请 | 保留，确认首次启动不主动申请 |
| `ohos.permission.ACCESS_BIOMETRIC` | `entry/src/main/module.json5` | 主机安全锁、TOTP 隐私保护 | 保留，确认仅功能触发时使用 |
| `ohos.permission.ACTIVITY_MOTION` | `entry/src/main/module.json5` | 握持/沉浸式适配检测 | 发布前必须真机确认功能入口；若无明确用户价值，应移除或延后 |
| `ohos.permission.DETECT_GESTURE` | `entry/src/main/module.json5` | 握持/沉浸式适配检测 | 发布前必须真机确认功能入口；若无明确用户价值，应移除或延后 |

## 三、能力文案真实性

| 能力 | 当前状态 | 文案要求 |
|---|---|---|
| RustDesk | 已完成阶段性连接、音频、输入、视频与中继配置链路 | 可作为核心能力描述，但避免承诺兼容所有自建服务器 |
| SSH | SSH 终端、密钥、预检、触控滚动已完成阶段性闭环 | 可作为核心能力描述 |
| RDP | FreeRDP 真链路仍需按构建开关和真机验证确认 | 可描述为 RDP 入口和持续验证能力，不得承诺所有企业网关/重定向能力 |
| VNC | `entry/src/main/cpp/vnc/vnc_adapter.cpp` 仍是 mock | 只写“预留/规划中入口”或隐藏；不得写成完整可用 |
| 系统剪贴板 | native `clipboard_bridge.cpp` 仍需确认是否接入真实系统 pasteboard；部分路径可能只是缓存/会话内转发 | 只描述文本粘贴/会话剪贴能力，避免承诺完整系统双向同步 |
| 麦克风采集 | `audio_capturer.cpp` 存在 TODO/mock 风险 | 不得承诺麦克风转发，除非后续完成 OHAudio capturer smoke |
| 文件传输 | RDP drive/RustDesk file 入口存在，但后台队列/取消/重试仍待强化 | 可描述基础文件发送，避免承诺后台可靠队列 |

## 四、敏感信息与日志

| 检查项 | 当前风险 | 发布前动作 |
|---|---|---|
| 连接日志 | `RemoteDesktop.ets`、`HostListPage.ets` 存在 host/user/domain/credential 相关日志 | 引入 SafeLogger 后统一 mask/hash |
| 原生日志 | `extension_loader_napi.cpp`、RDP/RustDesk/SSH 适配层可能输出主机、用户、配置字段 | 引入 native safe_log 后替换高风险日志 |
| AGC 密钥 | `agconnect-services.json` 含 `client_secret`、`api_key` | 发布包必须替换为正式配置；仓库中只保留可公开的示例或明确标记的本地配置 |
| SSH 私钥/TOTP secret | ArkTS 类型、UI、服务中有字段定义 | 允许字段名和 UI 占位存在；禁止运行日志输出实际值 |
| 错误对象 | 多处 `JSON.stringify(err)` | 保留错误码/阶段/消息，避免展开可能包含 ValuesBucket 或凭据的对象 |

## 五、验收命令

```powershell
rg -n "com.example.remotedesktop|client_secret|api_key|passwordLen|privateKey|apiPassword|secret=|token=" AppScope entry/src/main docs/app-store
rg -n "VNC|麦克风|microphone|系统剪贴板|clipboard" docs/app-store
```

允许出现字段定义、权限说明和明确的“待验证/规划中”描述；不允许出现把 mock/未验证能力写成完整能力的商店文案。

## 六、发布前阻断项

1. `bundleName`、`vendor`、Release Profile、AGC 配置未确认时，不提交 AppGallery。
2. VNC、麦克风、系统剪贴板未完成真实接入前，不在应用市场描述中作为完整能力宣传。
3. SafeLogger/native safe_log 完成前，不提交含连接凭据调试日志的候选包。
4. 使用新版 ArkTS 测试入口 `default@OhosTestCompileArkTS` 与 `onDeviceTest` 验收；旧版 `default@OhosTestBuildArkTS` 无法加载 HarmonyOS 扩展 Kit，不作为发布阻断依据。
