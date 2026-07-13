# RDP 证书预检异步化与远程会话导航沉浸设计

## 目标

修复 RDP 证书预检弹窗中加载图标“卡死”的问题，并为 RDP/RustDesk 已建立远程会话提供会话级系统导航栏沉浸。证书信任判断、证书弹窗展示顺序、远程协议连接与输入/渲染语义保持不变。

## 已确认的根因

`HostListPage.ets` 的 `doRdpCertificateProbe` 虽然声明为 `async`，但定时器结束后仍直接调用同步的 `ExtensionLoader.probeRdpCertificate`。该调用经过同步 NAPI 进入 `FreeRdpAdapter::probeRdpCertificate`，会在 ArkTS/UI 线程执行 DNS、TCP connect、socket receive、TLS handshake 和 X509 校验。连接超时或网络不可达时，UI 线程无法处理 LoadingProgress 动画、取消按钮和弹窗重绘，所以表现为加载图标卡死。

## 方案决策

### 1. RDP 证书预检

新增 `probeRdpCertificateAsync` NAPI Promise 接口。NAPI 参数解析、Promise 创建和最终 JS 对象创建在 JS 线程执行；证书网络探测放到 `napi_create_async_work` 的 execute 回调中；complete 回调只负责把 `RdpCertificateInfo` 转成 JS 对象并 resolve/reject Promise。execute 回调不调用任何 NAPI API。

ArkTS 保留现有同步接口供兼容调用，但证书预检 UI 只使用异步接口。HostListPage 为每一次探测分配 generation，取消、重试、切换路由或宿主离开后递增 generation；异步结果回来时只有 generation 和 hostId 都仍然匹配才允许更新弹窗状态。这样不需要强杀 native socket，也不会让旧结果覆盖新一轮探测。

适配器不存在、async work 创建失败和 native 异常统一转成可见的证书探测错误；既有证书 flags、fingerprint、rootTrusted、hostMismatch 和错误码原样传递，不改变信任策略。

### 2. 远程会话导航沉浸

新增纯 ArkTS `RemoteImmersivePolicy`，只允许 `rdp` 和 `rustdesk` 在 `connected=true` 时进入隐藏导航模式。连接成功和后台恢复渲染成功后调用窗口的 `setSpecificSystemBarEnabled('navigation', false, false)`；对 `navigationIndicator` 做 best-effort 调用，设备/API 不支持时记录诊断日志并继续保持远程连接。

显式返回、断开按钮、连接错误和清理流程恢复导航栏。系统回桌面/后台保活路径不主动恢复，以避免系统回到桌面时出现导航栏闪烁；前台恢复完成后再次应用隐藏。SSH/VNC、证书弹窗、主机列表和未连接页面不改变系统导航栏策略。

“第一次上滑显示导航条、第二次上滑回主页”属于系统导航手势仲裁，应用无法可靠地接管或保证次数。产品侧只负责隐藏导航栏并让系统处理边缘上滑；不在远程 XComponent 上增加自定义底部上滑手势，避免与远程触控转发冲突。验收时分别覆盖手势导航、三键导航、2in1/自由窗口和后台恢复。

## 错误处理与可观测性

- RDP async worker 的错误结果保留现有证书错误码和错误信息；Promise rejection 只用于桥接层失败。
- ArkTS 异步结果失效时静默丢弃，不改变当前弹窗；每个忽略路径保留带固定诊断码的日志。
- 导航栏 API 失败不影响连接，不触发断连；记录 `E-IMMERSIVE-NAV-HIDE`、`E-IMMERSIVE-NAV-RESTORE` 和 `E-IMMERSIVE-NAV-INDICATOR` 诊断码。
- 异步 native work 不在页面销毁时强行释放 adapter；页面只丢弃迟到结果，避免后台线程使用已释放的 NAPI 状态。

## 验收标准

1. RDP 证书探测期间 LoadingProgress 可持续动画，取消按钮能在探测未完成时响应。
2. 探测超时后弹窗显示既有错误状态；重试结果不会被上一轮迟到结果覆盖。
3. RDP/RustDesk 连接成功后导航栏隐藏；显式退出后恢复；后台保活恢复后再次隐藏。
4. SSH/VNC、主机列表和证书预检页面的导航栏行为不变。
5. 异步接口、探测生命周期策略和沉浸策略有测试；API 23 目标构建通过；现有 native policy tests 和 ArkTS ohosTest 编译/设备测试不回退。
