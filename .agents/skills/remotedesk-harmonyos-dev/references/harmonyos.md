# 鸿蒙开发与工具链

当前开发基准：API 26，用户于 2026-09-07 确认。当天核验的项目样例与本地配置 target/compatible 仍为 `6.1.0(23)`；这表示保留的目标/安装兼容配置，不能反推开发基准仍停在 API 23。full SDK 与独立 OpenHarmony SDK 已有 API 26；native 脚本实际选用的 SDK/ABI 另行核对。读取私有配置时只提取版本字段，不输出签名信息。

## API 与平台证据

1. 新开发先查本地 API 26 文档和实际 SDK `.d.ts`/NDK `.h`：符号存在、`@since`、权限、系统能力、设备条件、线程及释放约束。
2. macOS 用 [macos_env.sh](../../../../scripts/macos_env.sh) 与 [resolve_ohos_sdk.sh](../../../../scripts/resolve_ohos_sdk.sh) 发现 SDK；全量 HarmonyOS SDK 用于 Hvigor/HMS Kits，OpenHarmony native SDK 用于 NDK/交叉编译。不能互换。已安装的 full SDK 版本、应用 target/compatible 和 native SDK 版本分别核实。
3. 开发采用 API 26 基准；保留 API 23 安装兼容时，新增接口必须检查静态导入、初始化、运行时能力与回退，不能仅在按钮回调中判断版本。基准推进不等于提高最低安装版本或完成所有新 API 接入。
4. 本地信息不足再查华为官方当前文档，保留具体页面、API 版本和核验日期；离线时注明未验证点。

本地复查命令示例（先 source 环境并确认 full SDK 的元数据为 API 26；以下查 full SDK 的声明，不改变现有 native 构建选择）：

```sh
rg -n 'WindowEventType|setWindowPrivacyMode' "$DEVECO_SDK_HOME/default/openharmony/ets/api/@ohos.window.d.ts"
rg -n 'OH_NativeImage_UpdateSurfaceImage|OH_NativeImage_GetTransformMatrixV2' "$DEVECO_SDK_HOME/default/openharmony/native/sysroot/usr/include/native_image/native_image.h"
```

独立 SDK layout 使用 `ets/api` 和 `native/sysroot/usr/include`。检查实际元数据后选择对应根；不把任一机器的绝对路径写进 skill。`macos_env.sh` 当前可能仍选择 API 23 独立 native 工具链，不能将其输出误认成 API 26；native 迁移按单独授权任务与 ABI 验证推进。

## 已核验 API 26 NDK 约束

本地 API 26 `native_image/native_image.h`：`OH_NativeImage_UpdateSurfaceImage` 要求在 OpenGL ES context 线程调用；接口非线程安全。`OH_NativeImage_GetTransformMatrixV2` 的矩阵依赖更新过的 surface image。修改时重新查看该头文件的完整契约与返回值。

在项目 [hw_decoder.cpp](../../../../entry/src/main/cpp/render/hw_decoder.cpp) 和 [gl_renderer.cpp](../../../../entry/src/main/cpp/render/gl_renderer.cpp) 核对实际线程、surface/context 和矩阵应用。不要把 frame callback 收到消息解释成画面已经提交。

API 26 `@ohos.window.d.ts` 提供 `windowEvent` 的 on/off；listener 生命周期需与实际窗口 owner 对齐。事件名字存在不证明所有设备、窗口模式行为相同。

## ArkTS 与 UI 工程经验

- 使用明确的 interface、回调和返回类型；遇到 ArkTS 编译错误按具体诊断收敛，不用 TypeScript 通过替代 Hvigor 通过。
- 复用当前主题、资源、断点和设置行组件；检查深浅色、文本放大、窄屏、PC/Pad/Phone、键盘遮挡、底部安全区及可访问名称。
- `bindSheet` 先检查宿主是否仍挂载、弹层状态由谁持有、关闭后是否还有异步回调。不要把一次失败直接归因于固定“弹层数量上限”。
- ArkUI 的 vp、窗口/画布像素、远端桌面像素应明确标记；设备 density 与远端分辨率不相等。
- 剪贴板读取权限、前后台状态和监控恢复分别检查；[ClipboardBridgeService.ets](../../../../entry/src/main/ets/services/ClipboardBridgeService.ets) 处理 permission change 与监听生命周期，不在轮询热路径同步读取空剪贴板。
- app clone/多窗口/账户不共享身份假设；查 [AppCloneContext.ets](../../../../entry/src/main/ets/services/AppCloneContext.ets) 及 scope 策略。

这些是本项目检查点，非所有鸿蒙应用的一刀切规则。来源：[DECISIONS.md](../../../../docs/codex/DECISIONS.md) 的 API/NDK/UI 条目及上述实现。

API 26 本地 `@ohos.arkui.uiMaterial.d.ts` 中 `uiMaterial` 标为 `@since 26.0.0`，由 `@kit.ArkUI` 导出；不要臆造 `@kit.uiMaterial` 入口。ContainerReader 与 DynamicLayout 等组件也按各自声明核验，不能仅按名称或开发基准推断设备可用。

UIDesignKit/HDS 不能整体归为 API26 专属；当前项目使用的 `hdsMaterial` 在本地 HMS 声明为 `@since 6.1.0(23)`。按具体符号查版本。

## API 26 接入与系统集成

[2026-08-19-harmonyos7-api26-app-wide-ui-upgrade-plan.md](../../../../docs/codex/plans/2026-08-19-harmonyos7-api26-app-wide-ui-upgrade-plan.md) 是历史升级方案证据，当前实施路线从 CURRENT/QUEUE 指向的更新计划读取。公共 UI 的 API 26 升级独立于 Pro；碰一碰、分享、接续、系统认证等具体能力需要分别验证 API、授权、设备和产品路由。开发基准已推进，具体组件的规划/实现/验收状态仍逐项核实。不要用控制端已实现推导系统级被控端权限已具备。

## 工具链坑位

构建产物使用 checkout 内稳定目录。不要将持久符号链接指向重启后可能消失的临时目录，也不要迁移另一设备的 SDK/cache/签名配置。先检查路径类型、真实目标、SDK/ABI 和权限，再处理 ENOTDIR/EPERM；不批量删除用户数据或依赖缓存。

本项目 [macos_hvigorw.sh](../../../../scripts/macos_hvigorw.sh) 是 Hvigor 路径保护入口；NDK 平台替代和链接库按当前头文件及 CMake 验证，不假定所有 Linux `std::filesystem`/随机数实现可直接移植。构建命令见 [验证](validation.md)。
