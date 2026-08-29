# RustDesk 手机画面与控制快速优化方案

状态：已实施并通过本地构建门禁，待 Android 真机横竖屏与触控验收。

## 目标

优先解决控制手机时的画面翻转、横竖屏比例错误、缩放跳变和点击坐标偏移；同时修正长按、双指和异常中断后的控制问题。沿用现有 RustDesk 协议、解码器和渲染器，不做大规模重构。

## 实施步骤

### 1. 固定画面方向契约（最高优先级）

- 将“解码纹理方向”和“用户手动画面旋转”分成两层：NativeImage 矩阵只修正纹理坐标，`canvasRotationQuarterTurns` 只处理用户旋转，禁止相互补偿或重复翻转。
- NativeImage 变换明确覆盖 identity、flip-X、flip-Y、90°、180°、270°及其轴交换；同一解码代可保留最近有效矩阵，解码尺寸或方向代际变化时必须先清掉旧矩阵。
- 横竖屏切换以 RustDesk `SwitchDisplay` 的逻辑宽高为准；新几何生效前保留旧画面，新代首帧到达后一次性提交方向、源尺寸和视口。
- 保留诊断字段：逻辑宽高、解码宽高、producer transform、canvas rotation、最终 viewport，方便直接判断是哪一层翻转。

主要文件：

- `entry/src/main/cpp/render/native_image_context_policy.h`
- `entry/src/main/cpp/render/hw_decoder.cpp`
- `entry/src/main/cpp/render/gl_renderer.cpp`
- `entry/src/main/cpp/rustdesk/rustdesk_peer_presentation_policy.h`

### 2. 收敛缩放与窗口适配

- 只保留一个缩放公式：`最终比例 = contain(Fit) × 用户倍率`；Fit 始终完整居中，100% 始终代表一个远端像素对应一个本地物理像素。
- 方向为 90°/270° 时先交换逻辑宽高，再计算 Fit、缩放边界和可平移范围。
- 横竖屏切换、窗口变化、远端分辨率变化时：未手动缩放则重新 Fit；用户已缩放则保留倍率、重新约束平移，避免突然放大、裁切或跑出屏幕。
- native 提交视口后立即重绘保留帧；ArkTS 输入映射只读取同一版本的源尺寸、旋转和 viewport，禁止混用新旧几何。

主要文件：

- `entry/src/main/ets/services/RemoteCanvasTransformPolicy.ets`
- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/cpp/render/gl_renderer.cpp`

### 3. 对齐官方手机触控

- 根据真实 `PeerInfo.platform` 识别 Android，主机手工类型仅作握手前回退。
- Android 直接触控使用 `MOVE → LEFT_DOWN → MOVE* → LEFT_UP`；删除本地 650ms 长按转右键，长按交给被控 Android RustDesk 服务识别。
- Android 直接触控下双指只缩放/平移本地画布，不发送右键；触控板模式仍可保留双指右键。
- 增加统一释放入口，在 Cancel、旋转、缩放模式切换、浏览模式、退后台和断线前补齐一次 Up，避免远端残留拖动。
- 远端输入权限为 false 时阻止新手势并提示开启 RustDesk Input Control/无障碍权限。

主要文件：

- `entry/src/main/ets/pages/RemoteDesktop.ets`
- `entry/src/main/cpp/rustdesk/rustdesk_bridge.cpp`
- `rustdesk_ffi/src/lib.rs`

## 最小测试与验收

1. Native：identity、flip-X、flip-Y、180°、未知矩阵、矩阵读取失败和方向切换不得继承旧翻转。
2. ArkTS：Fit/100%/双指缩放在 0°、90°、180°、270° 下视口和输入坐标一致。
3. 真机：Android 竖屏/横屏各验证连接、旋转、Fit、100%、双指缩放、点击、滑动、长按和断线中断。
4. 通过标准：无上下/左右翻转；Fit 不裁切；横竖屏切换不跳变；画面与点击误差不超过 2 个远端像素；无残留按下。
5. 执行定向测试、两项 Hvigor 门禁、`git diff --check`、Light 合规和独立复核后再交付。

## 暂不做

- 不新增原始多点触控协议。
- 不重写解码器、渲染器或 RustDesk 连接流程。
- 不增加复杂的逐主机显示配置、动画或新的设置页面。
- 不顺带处理与本问题无关的画质、码率和文件传输功能。

## 本轮落地

- NativeImage 接受 8 类安全轴对齐方向矩阵；首帧或后续关键帧尺寸变化时重建固定尺寸解码表面。
- 窗口、码流和显示器几何变化保留用户缩放倍率与中心焦点，未手动缩放仍回到 Fit。
- Android/iOS 手机会话以真实 peer platform 为准；直接触控不再把本地长按改成右键，双指不触发右键。
- 浏览模式、权限关闭、模式切换和触控取消统一释放按键；远端未开放输入权限时阻止新输入并提示。

## 官方对齐参考

- [RustDesk CanvasModel](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/models/model.dart)：Fit、Custom、焦点缩放与本地平移。
- [RustDesk remote_input.dart](https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/common/widgets/remote_input.dart)：手机 Touch Mode 的单指和双指语义。
- [RustDesk Android InputService.kt](https://github.com/rustdesk/rustdesk/blob/master/flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/InputService.kt)：MouseEvent 到 Android Accessibility 手势的转换。
