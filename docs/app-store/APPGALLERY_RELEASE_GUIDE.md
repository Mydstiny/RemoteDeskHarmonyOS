# AppGallery 上架准备与提交流程

更新日期：2026-06-30

## 一、当前已准备

1. 已准备隐私政策：`docs/app-store/PRIVACY_POLICY.md`
2. 已准备用户使用文档：`docs/app-store/USER_GUIDE.md`
3. 已新增发布与隐私自查清单：`docs/app-store/RELEASE_PRIVACY_CHECKLIST.md`
4. 应用内设置页新增简单使用教程和关于应用弹窗入口。
5. 引导页已按当前协议入口、云同步、安全和 PC 适配能力重构。
6. 权限声明已集中在 `entry/src/main/module.json5`，相机和生物识别为使用时授权。

## 二、上架前仍需人工确认

1. 包名仍为 `com.example.remotedesktop`，正式上架前必须改为最终包名，并在 AppGallery Connect 使用同一包名创建应用。包名上架后不可更改。
2. 当前签名配置使用 Debug Profile：`remote_desktopDebug (1).p7b`。上架必须替换为 Release Profile。
3. `agconnect-services.json` 必须从正式 AGC 应用重新下载并替换；当前文件包含调试应用的 `client_secret`、`api_key` 和示例包名，不应直接作为发布配置。
4. RDP 真机完整链路、主机安全锁持久化、AppGallery 审核机型兼容性仍需真机验证。
5. VNC、系统剪贴板、麦克风和后台文件队列仍需按实际能力降级文案或补齐实现。
6. 需要准备 3 到 8 张真实截图，建议覆盖登录/主机/添加主机/远程连接/密钥保险库/设置页。

## 三、建议应用市场文案

应用名称：远程桌面

应用简介：HarmonyOS 原生远程连接工具

应用描述：

远程桌面是一款面向 HarmonyOS NEXT 的原生远程连接工具，提供 RDP、RustDesk、SSH 连接能力，并预留 VNC 等扩展入口。应用提供主机列表管理、RustDesk 中继配置、SSH 终端、密钥保险库、TOTP 一次性验证码、华为账号云同步和端到端加密能力。

应用适合远程办公、家庭设备访问、服务器维护和跨设备协作。敏感数据在本地加密后同步，远程连接数据直接在你的设备与目标主机之间传输，不经过作者服务器。

## 四、构建 Release 包

1. 在 AppGallery Connect 创建 HarmonyOS 应用，确认最终包名。
2. 下载 Release Profile 和正式 `agconnect-services.json`。
3. 替换 `build-profile.json5` 中签名材料。
4. 替换 `entry/src/main/resources/rawfile/agconnect-services.json`。
5. 执行 release 构建：

```powershell
cd "C:\Users\14288\DevEcoStudioProjects\RemoteDesktop"
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' `
  'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry -p product=default assembleHap `
  --analyze=normal --parallel --incremental --daemon
```

构建产物通常位于：

`entry/build/default/outputs/default/entry-default-signed.hap`

## 五、AppGallery Connect 提交步骤

1. 登录 AppGallery Connect。
2. 创建项目和 HarmonyOS 应用，包名必须与 `AppScope/app.json5` 一致。
3. 开通 Account Kit、Cloud DB、生物识别相关能力，并按项目实际需要配置云数据库表。
4. 上传 HAP 包。
5. 填写基本信息、应用分类、标签、隐私政策链接、权限用途说明。
6. 上传应用图标和 3 到 8 张真实截图。
7. 填写版本说明并提交审核。

首次发布版本说明建议：

```text
首次发布

核心功能：
- RDP、RustDesk、SSH 远程连接能力，预留 VNC 扩展入口
- RustDesk 中继服务器管理
- SSH 终端、密钥保险库和 TOTP 验证器
- 华为账号登录与跨设备云同步
- 主密码加密与沉浸式多端界面
```

## 六、审核重点自查

1. 首次进入应用不能在未授权前收集非必要个人信息。
2. 权限申请必须发生在功能触发时，相机只用于 TOTP 扫码，生物识别只用于安全验证。
3. 设置页必须能看到版本、使用教程、关于应用和隐私政策入口或链接。
4. 所有按钮应有响应，空状态应可理解。
5. 真机连续使用、断网、登录失败、连接失败、切后台恢复都不能崩溃。
6. 按 `RELEASE_PRIVACY_CHECKLIST.md` 逐项确认后再上传候选包。
